/// LRU runtime scheduler (architecture §5.2).
///
/// Coordinates loading/unloading across capabilities:
///  * every use refreshes `lastUsedAt`
///  * concurrent loads of the same model share one in-flight future, so a
///    model is never initialised twice
///  * a blocking compatibility issue fails the load before the adapter
///    touches the file (see `ModelCompatibilityChecker`)
///  * every load phase is published as a [ModelLoadProgress], so an app can
///    show a real loader instead of an indeterminate spinner
///  * loading beyond `maxLoadedModels` evicts the least-recently-used
///    unlocked, unpinned model
///  * a periodic sweep unloads models idle longer than `unloadUnusedAfter`
///  * `onAppBackground()` unloads all unlocked models when
///    `trimOnBackground` is set
///  * gpu/npu load failures automatically fall back to cpu, reported via
///    [RuntimeBackendFallback]
library;

import 'dart:async';

import 'package:local_ai_core/local_ai_core.dart';

class RuntimeScheduler implements LocalModelRuntime {
  RuntimeScheduler({
    required LocalModelCatalog catalog,
    required AdapterRegistry registry,
    RuntimeMemoryPolicy policy = const RuntimeMemoryPolicy(),
    Clock clock = Clock.system,
    Future<DeviceCapabilities> Function()? deviceProbe,
    Duration sweepInterval = const Duration(seconds: 30),
    Object? Function(LocalModelManifest manifest)? loadOptionsFor,
    ModelCompatibilityPolicy compatibilityPolicy =
        const ModelCompatibilityPolicy(),
    CompatibilityEnforcement compatibilityEnforcement =
        CompatibilityEnforcement.enforce,
    Duration capabilitiesTtl = const Duration(seconds: 30),
  })  : _catalog = catalog,
        _registry = registry,
        _policy = policy,
        _clock = clock,
        _deviceProbe = deviceProbe,
        _loadOptionsFor = loadOptionsFor,
        _compatibilityPolicy = compatibilityPolicy,
        _compatibilityEnforcement = compatibilityEnforcement,
        _capabilitiesTtl = capabilitiesTtl {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweepIdle());
  }

  final LocalModelCatalog _catalog;
  final AdapterRegistry _registry;
  final RuntimeMemoryPolicy _policy;
  final Clock _clock;
  final Future<DeviceCapabilities> Function()? _deviceProbe;
  final ModelCompatibilityPolicy _compatibilityPolicy;
  final CompatibilityEnforcement _compatibilityEnforcement;
  final Duration _capabilitiesTtl;

  /// Supplies per-manifest load options from the app config (e.g.
  /// [LlmLoadOptions] carrying `maxContextTokens` / `temperature`).
  final Object? Function(LocalModelManifest manifest)? _loadOptionsFor;

  final Map<String, _LoadedHandle> _handles = {};
  final _events = StreamController<RuntimeEvent>.broadcast();
  Timer? _sweepTimer;
  DeviceCapabilities? _capabilities;
  DateTime? _capabilitiesProbedAt;

  /// One future per in-flight load, so N concurrent `ready()` calls for the
  /// same model produce one native load instead of N.
  final Map<String, Future<void>> _loading = {};
  final Map<String, StreamController<ModelLoadProgress>>
      _loadProgressControllers = {};
  final Map<String, ModelLoadProgress> _lastLoadProgress = {};
  final Map<String, Duration> _lastLoadDurations = {};
  final Set<String> _pinned = {};

  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;
  int _idleUnloads = 0;
  bool _sweeping = false;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  @override
  List<LoadedModel> get loadedModels =>
      _handles.values.map((h) => h.info).toList(growable: false);

  /// Returns the loaded adapter instance for [modelId] (typed by caller).
  ///
  /// Facades use this to reach the shared adapter the scheduler loaded.
  T adapter<T>(String modelId) {
    final handle = _handles[modelId];
    if (handle == null) {
      throw InvalidStateError('Model "$modelId" is not loaded.');
    }
    final adapter = handle.adapter;
    if (adapter is! T) {
      throw InvalidStateError(
        'Model "$modelId" is loaded as ${adapter.runtimeType}, which is not '
        'a $T. The manifest\'s provider resolves to the wrong adapter '
        'capability.',
      );
    }
    // `is! T` does not promote a local of static type Object to a type
    // variable, so the cast stays — it cannot fail after the check.
    return adapter as T;
  }

  /// Whether [modelId] is currently loaded.
  bool isLoaded(String modelId) => _handles.containsKey(modelId);

  /// Locks/unlocks a *loaded* model against eviction (voice sessions lock
  /// their components for the session lifetime).
  ///
  /// A lock applies only while the model stays loaded; use [setPinned] for
  /// a lock that survives across loads.
  void setLocked(String modelId, {required bool locked}) {
    final handle = _handles[modelId];
    if (handle != null) {
      handle.info = handle.info.copyWith(locked: locked);
    }
  }

  @override
  void setPinned(String modelId, {required bool pinned}) {
    if (pinned) {
      _pinned.add(modelId);
    } else {
      _pinned.remove(modelId);
    }
    setLocked(modelId, locked: pinned);
  }

  @override
  Set<String> get pinnedModels => Set.unmodifiable(_pinned);

  @override
  ModelCacheStats get cacheStats => ModelCacheStats(
        loadedModelIds: _handles.keys.toList(growable: false),
        maxLoadedModels: _policy.maxLoadedModels,
        hits: _hits,
        misses: _misses,
        evictions: _evictions,
        idleUnloads: _idleUnloads,
        lastLoadDurations: Map.unmodifiable(_lastLoadDurations),
      );

  /// Refreshes the LRU timestamp for [modelId] (called by facades on every
  /// generate/transcribe/speak).
  void touch(String modelId) {
    final handle = _handles[modelId];
    if (handle != null) {
      handle.info = handle.info.copyWith(lastUsedAt: _clock.now());
    }
  }

  @override
  Stream<ModelLoadProgress> loadProgress(String modelId) {
    final controller = _loadProgressControllers.putIfAbsent(
        modelId, () => StreamController<ModelLoadProgress>.broadcast());
    final last = _lastLoadProgress[modelId];
    if (last == null || last.isTerminal) return controller.stream;
    // Replay the in-flight phase so a widget that subscribes mid-load
    // renders a loader instead of a blank screen until the next phase.
    return Stream<ModelLoadProgress>.multi(
      (subscriber) {
        subscriber.add(last);
        final sub = controller.stream.listen(
          subscriber.add,
          onError: subscriber.addError,
          onDone: subscriber.close,
        );
        subscriber.onCancel = sub.cancel;
      },
      isBroadcast: true,
    );
  }

  @override
  Future<Map<String, Object?>> warmUp(
    List<String> modelIds, {
    RuntimePreference? preference,
  }) async {
    final results = <String, Object?>{};
    // Sequential on purpose: two native loads at once compete for exactly
    // the memory the scheduler is trying to budget.
    for (final modelId in modelIds) {
      try {
        await loadModel(modelId, preference: preference);
        results[modelId] = null;
      } on Object catch (e) {
        results[modelId] = e;
      }
    }
    return results;
  }

  @override
  Future<void> loadModel(String modelId,
      {RuntimePreference? preference}) async {
    if (_handles.containsKey(modelId)) {
      _hits++;
      touch(modelId);
      return;
    }
    // Coalesce: a second caller waits on the first load instead of
    // starting its own and leaking one of the two native handles.
    // A joiner does not re-emit a phase: `loadProgress` replays the real
    // in-flight phase to it, and a synthetic `queued` would rewind that.
    final inFlight = _loading[modelId];
    if (inFlight != null) return inFlight;
    _misses++;
    // The callback must be a block, not an expression: `Map.remove` returns
    // the removed value — here the very future being built — and
    // `whenComplete` waits on a Future its callback returns, so the
    // arrow form deadlocks the load against itself.
    final future = _loadInternal(modelId, preference).whenComplete(() {
      _loading.remove(modelId);
    });
    _loading[modelId] = future;
    return future;
  }

  Future<void> _loadInternal(
      String modelId, RuntimePreference? preference) async {
    final startedAt = _clock.now();
    _emitLoadPhase(modelId, ModelLoadPhase.queued, startedAt: startedAt);
    try {
      final manifest = await _catalog.get(modelId);
      await _gateCompatibility(manifest);

      final requested = preference ?? RuntimePreference.auto;
      _emitLoadPhase(modelId, ModelLoadPhase.evicting, startedAt: startedAt);
      await _evictIfNeeded(except: modelId);

      _emitLoadPhase(modelId, ModelLoadPhase.openingFiles,
          startedAt: startedAt);
      try {
        await _loadWithBackend(manifest, requested, startedAt);
      } on Object catch (e) {
        if (requested == RuntimePreference.cpu) rethrow;
        // Backend fallback: npu/gpu → cpu, reported via events (§5.2).
        _emit(RuntimeBackendFallback(
          modelId: modelId,
          requested: requested,
          effective: RuntimePreference.cpu,
          reason: '$e',
        ));
        _emitLoadPhase(modelId, ModelLoadPhase.initializingRuntime,
            startedAt: startedAt, detail: 'retrying on cpu after: $e');
        await _loadWithBackend(manifest, RuntimePreference.cpu, startedAt);
      }

      final duration = _clock.now().difference(startedAt);
      _lastLoadDurations[modelId] = duration;
      _emitLoadPhase(modelId, ModelLoadPhase.ready, startedAt: startedAt);
    } on Object catch (e) {
      _emitLoadPhase(modelId, ModelLoadPhase.failed,
          startedAt: startedAt, detail: '$e');
      rethrow;
    }
  }

  /// Runs the pre-load compatibility check and applies the enforcement
  /// policy. Always emits [RuntimeCompatibilityChecked] so an app can show
  /// warnings even when nothing blocks.
  Future<void> _gateCompatibility(LocalModelManifest manifest) async {
    if (_compatibilityEnforcement == CompatibilityEnforcement.off) return;
    final report = await checkCompatibility(manifest);
    _emit(RuntimeCompatibilityChecked(
      modelId: manifest.id,
      report: report,
    ));
    if (!report.isCompatible &&
        _compatibilityEnforcement == CompatibilityEnforcement.enforce) {
      throw IncompatibleDeviceError(report);
    }
  }

  Future<void> _loadWithBackend(
    LocalModelManifest manifest,
    RuntimePreference backend,
    DateTime startedAt,
  ) async {
    _emitLoadPhase(manifest.id, ModelLoadPhase.initializingRuntime,
        startedAt: startedAt, detail: 'backend=${backend.name}');
    final adapter = await _resolveAndLoad(manifest, backend);
    final now = _clock.now();
    final info = LoadedModel(
      modelId: manifest.id,
      type: manifest.type,
      backend: backend,
      loadedAt: now,
      lastUsedAt: now,
      locked: _pinned.contains(manifest.id),
      estimatedBytes: _estimateResidentBytes(manifest),
    );
    _handles[manifest.id] = _LoadedHandle(info: info, adapter: adapter);
    _emit(RuntimeModelLoaded(info));
  }

  /// Best-effort resident-size estimate used for memory accounting.
  ///
  /// Prefers the manifest's declared `minMemoryMB`; falls back to the size
  /// of the weight files, which a runtime maps more or less as-is.
  static int _estimateResidentBytes(LocalModelManifest manifest) {
    if (manifest.minMemoryMB > 0) return manifest.minMemoryMB * 1024 * 1024;
    return manifest.totalSizeBytes;
  }

  Future<Object> _resolveAndLoad(
      LocalModelManifest manifest, RuntimePreference backend) {
    final override = _loadOptionsFor?.call(manifest);
    switch (manifest.type) {
      case ModelType.llm:
        final adapter = _registry.resolveLlm(manifest);
        final options = override is LlmLoadOptions
            ? LlmLoadOptions(
                modelId: manifest.id,
                runtime: backend,
                maxContextTokens: override.maxContextTokens,
                temperature: override.temperature,
              )
            : LlmLoadOptions(modelId: manifest.id, runtime: backend);
        return adapter.load(options).then((_) => adapter);
      case ModelType.stt:
        final adapter = _registry.resolveStt(manifest);
        final options = override is SttLoadOptions
            ? override
            : SttLoadOptions(modelId: manifest.id);
        return adapter.load(options).then((_) => adapter);
      case ModelType.tts:
        final adapter = _registry.resolveTts(manifest);
        final options = override is TtsLoadOptions
            ? override
            : TtsLoadOptions(modelId: manifest.id);
        return adapter.load(options).then((_) => adapter);
      case ModelType.vad:
        final adapter = _registry.resolveVad(manifest);
        final options =
            override is VadConfig ? override : VadConfig(modelId: manifest.id);
        return adapter.load(options).then((_) => adapter);
      case ModelType.embedding:
        final adapter = _registry.resolveEmbedding(manifest);
        final options = override is EmbeddingLoadOptions
            ? override
            : EmbeddingLoadOptions(modelId: manifest.id);
        return adapter.load(options).then((_) => adapter);
    }
  }

  @override
  Future<void> unloadModel(String modelId) => _unload(modelId, 'explicit');

  Future<void> _unload(String modelId, String reason) async {
    final handle = _handles.remove(modelId);
    if (handle == null) return;
    try {
      final adapter = handle.adapter;
      if (adapter is LocalLlm) await adapter.unload();
      if (adapter is LocalStt) await adapter.unload();
      if (adapter is LocalTts) await adapter.unload();
      if (adapter is LocalVad) await adapter.unload();
      if (adapter is LocalEmbedding) await adapter.unload();
    } finally {
      if (reason == 'evicted') _evictions++;
      if (reason == 'idle' || reason == 'backgroundTrim') _idleUnloads++;
      _emit(RuntimeModelUnloaded(modelId, reason: reason));
    }
  }

  Future<void> _evictIfNeeded({required String except}) async {
    while (_handles.length >= _policy.maxLoadedModels) {
      final candidates = _handles.values
          .where((h) =>
              !h.info.locked &&
              !_pinned.contains(h.info.modelId) &&
              h.info.modelId != except)
          .toList();
      if (candidates.isEmpty) return; // everything locked: allow overshoot
      candidates.sort((a, b) => a.info.lastUsedAt.compareTo(b.info.lastUsedAt));
      await _unload(candidates.first.info.modelId, 'evicted');
    }
  }

  Future<void> _sweepIdle() async {
    // Timer.periodic does not wait for the previous tick; without this a
    // slow unload would let two sweeps unload the same model twice.
    if (_sweeping) return;
    _sweeping = true;
    try {
      final now = _clock.now();
      final idle = _handles.values
          .where((h) =>
              !h.info.locked &&
              !_pinned.contains(h.info.modelId) &&
              now.difference(h.info.lastUsedAt) > _policy.unloadUnusedAfter)
          .map((h) => h.info.modelId)
          .toList();
      for (final modelId in idle) {
        await _unload(modelId, 'idle');
      }
    } finally {
      _sweeping = false;
    }
  }

  /// Called by the kit when the app goes to background: unloads every
  /// unlocked model when the policy asks for it.
  Future<void> onAppBackground() async {
    if (!_policy.trimOnBackground) return;
    final unlocked = _handles.values
        .where((h) => !h.info.locked && !_pinned.contains(h.info.modelId))
        .map((h) => h.info.modelId)
        .toList();
    for (final modelId in unlocked) {
      await _unload(modelId, 'backgroundTrim');
    }
  }

  @override
  MemoryUsage get memoryUsage {
    final modelBytes =
        _handles.values.fold<int>(0, (sum, h) => sum + h.info.estimatedBytes);
    final capabilities = _capabilities;
    final total = (capabilities?.totalMemoryMB ?? 0) * 1024 * 1024;
    // `usedBytes` is what the models hold; without a platform RSS probe the
    // framework's own footprint is not visible from here.
    return MemoryUsage(
      totalBytes: total,
      usedBytes: modelBytes,
      modelBytes: modelBytes,
    );
  }

  @override
  Future<DeviceCapabilities> deviceCapabilities() async {
    final cached = _capabilities;
    final probedAt = _capabilitiesProbedAt;
    // Free RAM and free disk move; a permanently cached probe would gate
    // downloads on numbers from app start.
    final isFresh = cached != null &&
        probedAt != null &&
        _clock.now().difference(probedAt) < _capabilitiesTtl;
    if (isFresh) return cached;

    final probe = _deviceProbe;
    if (probe == null) {
      return const DeviceCapabilities(
        totalMemoryMB: 0,
        availableMemoryMB: 0,
        freeDiskMB: 0,
        platform: 'unknown',
      );
    }
    try {
      _capabilities = await probe();
      _capabilitiesProbedAt = _clock.now();
      return _capabilities!;
    } on Object {
      // A failing probe must not fail the load it was gating. Fall back to
      // the last good snapshot, or to "everything unknown".
      return cached ??
          const DeviceCapabilities(
            totalMemoryMB: 0,
            availableMemoryMB: 0,
            freeDiskMB: 0,
            platform: 'unknown',
          );
    }
  }

  @override
  Future<CompatibilityReport> checkCompatibility(
      LocalModelManifest manifest) async {
    final device = await deviceCapabilities();
    final requestedContext = _loadOptionsFor?.call(manifest);
    return ModelCompatibilityChecker.check(
      manifest: manifest,
      device: device,
      policy: _compatibilityPolicy,
      requestedContextTokens: requestedContext is LlmLoadOptions
          ? requestedContext.maxContextTokens
          : null,
    );
  }

  // ---------------------------------------------------------------------------

  void _emit(RuntimeEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  void _emitLoadPhase(
    String modelId,
    ModelLoadPhase phase, {
    DateTime? startedAt,
    String? detail,
  }) {
    final progress = ModelLoadProgress(
      modelId: modelId,
      phase: phase,
      elapsed: startedAt == null
          ? Duration.zero
          : _clock.now().difference(startedAt),
      expectedDuration: _lastLoadDurations[modelId],
      detail: detail,
    );
    _lastLoadProgress[modelId] = progress;
    final controller = _loadProgressControllers[modelId];
    if (controller != null && !controller.isClosed) controller.add(progress);
    _emit(RuntimeModelLoadProgress(progress));
  }

  /// Stops the sweep timer and unloads everything.
  Future<void> dispose() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final ids = _handles.keys.toList();
    for (final id in ids) {
      await _unload(id, 'dispose');
    }
    for (final controller in _loadProgressControllers.values) {
      await controller.close();
    }
    _loadProgressControllers.clear();
    await _events.close();
  }
}

class _LoadedHandle {
  _LoadedHandle({required this.info, required this.adapter});

  LoadedModel info;
  final Object adapter;
}
