/// LRU runtime scheduler (architecture §5.2).
///
/// Coordinates loading/unloading across capabilities:
///  * every use refreshes `lastUsedAt`
///  * loading beyond `maxLoadedModels` evicts the least-recently-used
///    unlocked model
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
  })  : _catalog = catalog,
        _registry = registry,
        _policy = policy,
        _clock = clock,
        _deviceProbe = deviceProbe,
        _loadOptionsFor = loadOptionsFor {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweepIdle());
  }

  final LocalModelCatalog _catalog;
  final AdapterRegistry _registry;
  final RuntimeMemoryPolicy _policy;
  final Clock _clock;
  final Future<DeviceCapabilities> Function()? _deviceProbe;

  /// Supplies per-manifest load options from the app config (e.g.
  /// [LlmLoadOptions] carrying `maxContextTokens` / `temperature`).
  final Object? Function(LocalModelManifest manifest)? _loadOptionsFor;

  final Map<String, _LoadedHandle> _handles = {};
  final _events = StreamController<RuntimeEvent>.broadcast();
  Timer? _sweepTimer;
  DeviceCapabilities? _capabilities;

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
    return handle.adapter as T;
  }

  /// Whether [modelId] is currently loaded.
  bool isLoaded(String modelId) => _handles.containsKey(modelId);

  /// Locks/unlocks a model against eviction (voice sessions lock their
  /// components for the session lifetime).
  void setLocked(String modelId, {required bool locked}) {
    final handle = _handles[modelId];
    if (handle != null) {
      handle.info = handle.info.copyWith(locked: locked);
    }
  }

  /// Refreshes the LRU timestamp for [modelId] (called by facades on every
  /// generate/transcribe/speak).
  void touch(String modelId) {
    final handle = _handles[modelId];
    if (handle != null) {
      handle.info = handle.info.copyWith(lastUsedAt: _clock.now());
    }
  }

  @override
  Future<void> loadModel(String modelId,
      {RuntimePreference? preference}) async {
    final existing = _handles[modelId];
    if (existing != null) {
      touch(modelId);
      return;
    }
    final manifest = await _catalog.get(modelId);
    final requested = preference ?? RuntimePreference.auto;
    await _evictIfNeeded(except: modelId);

    try {
      await _loadWithBackend(manifest, requested);
    } on Object catch (e) {
      if (requested == RuntimePreference.cpu) rethrow;
      // Backend fallback: npu/gpu → cpu, reported via events (§5.2).
      _events.add(RuntimeBackendFallback(
        modelId: modelId,
        requested: requested,
        effective: RuntimePreference.cpu,
        reason: '$e',
      ));
      await _loadWithBackend(manifest, RuntimePreference.cpu);
    }
  }

  Future<void> _loadWithBackend(
      LocalModelManifest manifest, RuntimePreference backend) async {
    final adapter = await _resolveAndLoad(manifest, backend);
    final now = _clock.now();
    final info = LoadedModel(
      modelId: manifest.id,
      type: manifest.type,
      backend: backend,
      loadedAt: now,
      lastUsedAt: now,
      estimatedBytes: manifest.minMemoryMB * 1024 * 1024,
    );
    _handles[manifest.id] = _LoadedHandle(info: info, adapter: adapter);
    _events.add(RuntimeModelLoaded(info));
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
      _events.add(RuntimeModelUnloaded(modelId, reason: reason));
    }
  }

  Future<void> _evictIfNeeded({required String except}) async {
    while (_handles.length >= _policy.maxLoadedModels) {
      final candidates = _handles.values
          .where((h) => !h.info.locked && h.info.modelId != except)
          .toList();
      if (candidates.isEmpty) return; // everything locked: allow overshoot
      candidates.sort((a, b) => a.info.lastUsedAt.compareTo(b.info.lastUsedAt));
      await _unload(candidates.first.info.modelId, 'evicted');
    }
  }

  Future<void> _sweepIdle() async {
    final now = _clock.now();
    final idle = _handles.values
        .where((h) =>
            !h.info.locked &&
            now.difference(h.info.lastUsedAt) > _policy.unloadUnusedAfter)
        .map((h) => h.info.modelId)
        .toList();
    for (final modelId in idle) {
      await _unload(modelId, 'idle');
    }
  }

  /// Called by the kit when the app goes to background: unloads every
  /// unlocked model when the policy asks for it.
  Future<void> onAppBackground() async {
    if (!_policy.trimOnBackground) return;
    final unlocked = _handles.values
        .where((h) => !h.info.locked)
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
    final total = (_capabilities?.totalMemoryMB ?? 0) * 1024 * 1024;
    return MemoryUsage(
      totalBytes: total,
      usedBytes: modelBytes, // best effort without platform RSS probe
      modelBytes: modelBytes,
    );
  }

  @override
  Future<DeviceCapabilities> deviceCapabilities() async {
    final cached = _capabilities;
    if (cached != null) return cached;
    final probe = _deviceProbe;
    if (probe == null) {
      return const DeviceCapabilities(
        totalMemoryMB: 0,
        availableMemoryMB: 0,
        freeDiskMB: 0,
        platform: 'unknown',
      );
    }
    return _capabilities = await probe();
  }

  @override
  Future<CompatibilityReport> checkCompatibility(
      LocalModelManifest manifest) async {
    final device = await deviceCapabilities();
    final reasons = <String>[];
    if (device.platform != 'unknown' &&
        manifest.platforms.isNotEmpty &&
        !manifest.platforms.contains(device.platform)) {
      reasons.add('platform ${device.platform} not in ${manifest.platforms}');
    }
    if (manifest.minMemoryMB > 0 &&
        device.totalMemoryMB > 0 &&
        device.totalMemoryMB < manifest.minMemoryMB) {
      reasons.add(
          'needs ${manifest.minMemoryMB}MB RAM, device has ${device.totalMemoryMB}MB');
    }
    if (reasons.isEmpty) return const CompatibilityReport.compatible();
    return CompatibilityReport(
      isCompatible: false,
      reasons: reasons,
      availableMemoryMB: device.totalMemoryMB,
      requiredMemoryMB: manifest.minMemoryMB,
    );
  }

  /// Stops the sweep timer and unloads everything.
  Future<void> dispose() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final ids = _handles.keys.toList();
    for (final id in ids) {
      await _unload(id, 'dispose');
    }
    await _events.close();
  }
}

class _LoadedHandle {
  _LoadedHandle({required this.info, required this.adapter});

  LoadedModel info;
  final Object adapter;
}
