/// The `LocalAI` facade: assembly + delegation only (architecture §3.6).
library;

import 'dart:async';

import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_flutter/local_ai_flutter.dart';

import '../catalog/catalog_service.dart';
import '../download/download_manager.dart';
import '../download/model_manager_impl.dart';
import '../pipeline/local_pipeline.dart';
import '../runtime/runtime_scheduler.dart';
import '../voice/voice_pipeline.dart';
import 'facades.dart';
import 'model_hub.dart';

/// Entry point of the kit.
///
/// ```dart
/// final ai = await LocalAI.initialize(
///   LocalAIConfig.offlineChat(),
///   plugins: [GemmaAdapterPlugin()],
/// );
/// final response = await ai.generate('Hello!');
/// ```
class LocalAI {
  LocalAI._({
    required this.config,
    required AdapterRegistry registry,
    required ModelCatalogService catalog,
    required ModelManagerImpl manager,
    required RuntimeScheduler scheduler,
    required LocalLlmFacade llmFacade,
    required LocalSttFacade sttFacade,
    required LocalTtsFacade ttsFacade,
    required LocalEmbeddingFacade embeddingFacade,
    required VoiceSessionFactory voiceFactory,
    required LocalAudioSource? audioSource,
    required LocalAudioOutput? audioOutput,
    SkillRegistry? skills,
  })  : _registry = registry,
        _catalog = catalog,
        _manager = manager,
        _scheduler = scheduler,
        _llmFacade = llmFacade,
        _sttFacade = sttFacade,
        _ttsFacade = ttsFacade,
        _embeddingFacade = embeddingFacade,
        _voiceFactory = voiceFactory,
        _audioSource = audioSource,
        _audioOutput = audioOutput,
        skills = skills ??
            SkillRegistry(initialPlugins: const [
              CalculatorSkill(),
              TimeSkill(),
              DeviceInfoSkill(),
              WeatherSkill(),
            ]),
        models = ModelHub(manager: manager, catalog: catalog);

  /// The active configuration.
  final LocalAIConfig config;

  /// `ai.skills`: MCP plugins & skill registry for tool calling.
  final SkillRegistry skills;

  final AdapterRegistry _registry;
  final ModelCatalogService _catalog;
  final ModelManagerImpl _manager;
  final RuntimeScheduler _scheduler;
  final LocalLlmFacade _llmFacade;
  final LocalSttFacade _sttFacade;
  final LocalTtsFacade _ttsFacade;
  final LocalEmbeddingFacade _embeddingFacade;
  final VoiceSessionFactory _voiceFactory;
  final LocalAudioSource? _audioSource;
  final LocalAudioOutput? _audioOutput;

  /// `ai.models`: install/remove/update/verify + download progress + packs.
  final ModelHub models;

  /// `ai.llm` facade (also reachable via the [generate] shortcuts).
  LocalLlmFacade get llm => _llmFacade;

  /// `ai.stt` facade.
  LocalSttFacade get stt => _sttFacade;

  /// `ai.tts` facade.
  LocalTtsFacade get tts => _ttsFacade;

  /// `ai.embeddings` facade (text embeddings for RAG / semantic search).
  ///
  /// Needs an embedding adapter registered for the configured model's
  /// provider — `LlamaCppAdapterPlugin` ships one; see docs/adapters.md.
  LocalEmbeddingFacade get embeddings => _embeddingFacade;

  /// `ai.voice`: full-duplex voice sessions with barge-in.
  VoiceSessionFactory get voice => _voiceFactory;

  /// `ai.runtime`: memory usage / loaded models / compatibility checks.
  LocalModelRuntime get runtime => _scheduler;

  /// Registered adapter registry (for diagnostics / plugin wiring).
  AdapterRegistry get adapters => _registry;

  /// Catalog access (list/get/refresh).
  LocalModelCatalog get catalog => _catalog;

  /// Shared microphone source (null when `enableAudio: false`).
  LocalAudioSource? get audioSource => _audioSource;

  /// Shared speaker output (null when `enableAudio: false`).
  LocalAudioOutput? get audioOutput => _audioOutput;

  /// The loaded VAD adapter for the configured VAD model. Used by the
  /// pipeline DSL; throws [InvalidStateError] when not loaded/configured.
  LocalVad get vadAdapter {
    final modelId = config.vad?.modelId;
    if (modelId == null) {
      throw const InvalidStateError('VAD is not configured.');
    }
    return _scheduler.adapter<LocalVad>(modelId);
  }

  /// `ai.genkit`: the orchestration escape hatch (architecture §3.5).
  ///
  /// Non-null only when `LlmConfig.enableGenkit` is set and the resolved
  /// LLM adapter implements `OrchestratorProvider` (e.g. via
  /// `GenkitAdapterPlugin`). Typed as [Object] here because the concrete
  /// `GenkitOrchestrator` lives in `local_ai_genkit`; that package ships an
  /// extension giving a strongly typed `ai.genkit` getter.
  Object? get genkitOrchestrator {
    final modelId = config.llm?.modelId;
    if (modelId == null || !_scheduler.isLoaded(modelId)) return null;
    final adapter = _scheduler.adapter<Object>(modelId);
    if (adapter is OrchestratorProvider) return adapter.orchestrator;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Convenience top-level delegates (task: ai.generate / ai.transcribe / ...)
  // ---------------------------------------------------------------------------

  /// One-shot text generation (delegates to [llm]).
  Future<LlmResponse> generate(
    String prompt, {
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
  }) =>
      _llmFacade.generate(
        prompt,
        systemPrompt: systemPrompt,
        temperature: temperature,
        maxTokens: maxTokens,
      );

  /// Streaming text generation (delegates to [llm]).
  Future<Stream<LlmChunk>> generateStream(LlmRequest request) =>
      _llmFacade.generateStream(request);

  /// Schema-validated structured output (delegates to [llm]).
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  }) =>
      _llmFacade.generateStructured(
        prompt,
        schema: schema,
        fromJson: fromJson,
        maxRetries: maxRetries,
      );

  /// Executes [prompt] with active MCP plugins and skills.
  ///
  /// The LLM automatically receives tool definitions, executes matching
  /// tool calls via [skills], and synthesizes a final response.
  Future<SkillExecutionResult> generateWithSkills(
    String prompt, {
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    SkillRegistry? customSkills,
  }) async {
    final activeRegistry = customSkills ?? skills;
    final llm = await _llmFacade.ready();
    final executor = SkillExecutor(registry: activeRegistry);
    return executor.execute(
      llm: llm,
      prompt: prompt,
      baseSystemPrompt: systemPrompt,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  /// One-shot transcription (delegates to [stt]).
  Future<Transcript> transcribe(AudioBuffer audio, {SttOptions? options}) =>
      _sttFacade.transcribe(audio, options: options);

  /// Streaming transcription (delegates to [stt]).
  Future<Stream<TranscriptEvent>> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) =>
      _sttFacade.transcribeStream(audio, options: options);

  /// Speaks [text] through the speaker (delegates to [tts]).
  Future<void> speak(
    String text, {
    String? voiceId,
    String? language,
    double? speed,
    double? pitch,
  }) =>
      _ttsFacade.speak(
        text,
        voiceId: voiceId,
        language: language,
        speed: speed,
        pitch: pitch,
      );

  /// Embeds [text] (delegates to [embeddings]).
  Future<List<double>> embed(String text) => _embeddingFacade.embed(text);

  /// Embeds a batch of [texts] (delegates to [embeddings]).
  Future<List<List<double>>> embedBatch(List<String> texts) =>
      _embeddingFacade.embedBatch(texts);

  /// Starts the typed pipeline DSL (architecture §5.4).
  LocalPipeline pipeline() => LocalPipeline(this);

  // ---------------------------------------------------------------------------
  // Warm-up
  // ---------------------------------------------------------------------------

  /// Model ids the current [config] wires up, in the order a voice session
  /// needs them.
  List<String> get configuredModelIds => <String>[
        if (config.vad != null) config.vad!.modelId,
        if (config.stt != null) config.stt!.modelId,
        if (config.llm != null) config.llm!.modelId,
        if (config.tts != null) config.tts!.modelId,
        if (config.embedding != null) config.embedding!.modelId,
      ];

  /// Downloads (if needed) and loads models ahead of first use, so the
  /// first `generate` / `transcribe` / `speak` returns without a
  /// multi-second stall.
  ///
  /// Defaults to every model in [config]. Progress per model is observable
  /// through `ai.runtime.loadProgress(modelId)` and
  /// `ai.models.downloadProgress(modelId)`.
  ///
  /// A failure on one model does not abort the rest: the returned map holds
  /// `null` for each model that is ready and the thrown error for each one
  /// that is not, so a caller can warm four models and surface only the one
  /// that failed.
  Future<Map<String, Object?>> warmUp({
    List<String>? modelIds,
    bool download = true,
  }) async {
    final ids = modelIds ?? configuredModelIds;
    final results = <String, Object?>{};
    for (final id in ids) {
      try {
        if (download) await models.ensureInstalled(id);
        // Loading an already-resident model is a no-op, so the backend is
        // fixed by whoever loads it first. Warming up without the configured
        // preference would silently pin the LLM to `auto` and leave later
        // requests unable to get the backend the app asked for.
        await _scheduler.loadModel(
          id,
          preference: id == config.llm?.modelId
              ? (config.llm!.runtime == RuntimePreference.auto
                  ? config.runtimePreference
                  : config.llm!.runtime)
              : null,
        );
        results[id] = null;
      } on Object catch (e) {
        results[id] = e;
      }
    }
    return results;
  }

  /// Keeps [modelId] resident: never evicted by the LRU policy, the idle
  /// sweep or a background trim.
  ///
  /// The right call for the one model an app uses constantly (the chat
  /// LLM) when a voice session keeps loading and unloading around it.
  void pinModel(String modelId) => _scheduler.setPinned(modelId, pinned: true);

  /// Releases a [pinModel] pin; the model becomes evictable again.
  void unpinModel(String modelId) =>
      _scheduler.setPinned(modelId, pinned: false);

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------

  /// Assembles the kit: storage → registry (+plugins) → catalog refresh →
  /// model manager crash recovery → runtime scheduler → facades.
  static Future<LocalAI> initialize(
    LocalAIConfig config, {
    List<AdapterPlugin> plugins = const [],
    List<LocalMcpPlugin>? mcpPlugins,
    bool enableAudio = true,
    LocalStoragePaths? paths,
    NetworkPolicy? networkPolicy,
    Future<DeviceCapabilities> Function()? deviceProbe,
    FreeDiskProbe? freeDiskProbe,
  }) async {
    final resolvedPaths = paths ?? await FlutterStoragePaths.resolve();
    await resolvedPaths.ensureInitialized();
    final resolvedNetwork = networkPolicy ?? FlutterNetworkPolicy();

    // The kit ships a real device probe; before this it was only used when
    // an app happened to pass one, which quietly turned every compatibility
    // check into "compatible" and every disk pre-flight into a no-op.
    final defaultProbe = FlutterDeviceProbe();
    final resolvedDeviceProbe = deviceProbe ?? defaultProbe.probe;
    // The disk pre-flight must see the disk as it is *now*: a second
    // download started inside the probe's cache window would otherwise be
    // sized against the free space the first one already claimed. Only the
    // probe we own can be force-refreshed; an app-supplied `deviceProbe`
    // keeps whatever caching its owner chose.
    final resolvedFreeDiskProbe = freeDiskProbe ??
        (deviceProbe == null
            ? (String _) async =>
                (await defaultProbe.probe(forceRefresh: true)).freeDiskMB
            : (String _) async => (await resolvedDeviceProbe()).freeDiskMB);

    // Audio stack (microphone + speaker) is created lazily-early here so
    // adapters receive shared instances in their AdapterContext.
    final audioSource = enableAudio ? FlutterAudioRecorder() : null;
    final audioOutput = enableAudio
        ? FlutterAudioPlayer(cacheDir: resolvedPaths.cacheDir)
        : null;

    final registry = AdapterRegistry()
      ..attachContext(AdapterContext(
        paths: resolvedPaths,
        networkPolicy: resolvedNetwork,
        audioSource: audioSource,
        audioOutput: audioOutput,
      ));
    for (final plugin in plugins) {
      plugin.register(registry);
    }

    final catalog = ModelCatalogService(
      paths: resolvedPaths,
      remoteCatalogUrl: config.remoteCatalogUrl,
    );
    await catalog.refresh();

    final manager = ModelManagerImpl(
      paths: resolvedPaths,
      catalog: catalog,
      networkPolicy: resolvedNetwork,
      freeDiskProbe: resolvedFreeDiskProbe,
      deviceProbe: resolvedDeviceProbe,
      compatibilityPolicy: config.compatibilityPolicy,
      compatibilityEnforcement: config.compatibilityEnforcement,
    );
    await manager.initialize();

    final scheduler = RuntimeScheduler(
      catalog: catalog,
      registry: registry,
      policy: config.memoryPolicy,
      deviceProbe: resolvedDeviceProbe,
      compatibilityPolicy: config.compatibilityPolicy,
      compatibilityEnforcement: config.compatibilityEnforcement,
      loadOptionsFor: (manifest) => switch (manifest.type) {
        ModelType.llm when config.llm != null => LlmLoadOptions(
            modelId: manifest.id,
            runtime: config.llm!.runtime,
            maxContextTokens: config.llm!.maxContextTokens,
            temperature: config.llm!.temperature,
          ),
        ModelType.stt when config.stt != null => SttLoadOptions(
            modelId: manifest.id,
            language: config.stt!.language,
            enablePunctuation: config.stt!.enablePunctuation,
          ),
        ModelType.tts when config.tts != null => TtsLoadOptions(
            modelId: manifest.id,
            voiceId: config.tts!.voiceId,
          ),
        ModelType.vad when config.vad != null => config.vad!,
        ModelType.embedding when config.embedding != null =>
          EmbeddingLoadOptions(
            modelId: manifest.id,
            dimensions: config.embedding!.dimensions,
          ),
        _ => null,
      },
    );

    final llmFacade = LocalLlmFacade(
      config: config.llm,
      defaultPreference: config.runtimePreference,
      models: manager,
      runtime: scheduler,
    );
    final sttFacade = LocalSttFacade(
      config: config.stt,
      models: manager,
      runtime: scheduler,
    );
    final ttsFacade = LocalTtsFacade(
      config: config.tts,
      models: manager,
      runtime: scheduler,
      audioOutput: audioOutput,
    );
    final embeddingFacade = LocalEmbeddingFacade(
      config: config.embedding,
      models: manager,
      runtime: scheduler,
    );
    final voiceFactory = VoiceSessionFactory(
      config: config,
      runtime: scheduler,
      audioSource: audioSource,
      audioOutput: audioOutput,
    );

    // App backgrounding trims unlocked models (architecture §5.2).
    final lifecycle = AppLifecycleObserver();
    final lifecycleSub = lifecycle.phases.listen((phase) {
      if (phase == AppLifecyclePhase.background) {
        scheduler.onAppBackground();
      }
    });

    final ai = LocalAI._(
      config: config,
      registry: registry,
      catalog: catalog,
      manager: manager,
      scheduler: scheduler,
      llmFacade: llmFacade,
      sttFacade: sttFacade,
      ttsFacade: ttsFacade,
      embeddingFacade: embeddingFacade,
      voiceFactory: voiceFactory,
      audioSource: audioSource,
      audioOutput: audioOutput,
      skills:
          mcpPlugins != null ? SkillRegistry(initialPlugins: mcpPlugins) : null,
    );
    ai._lifecycle = lifecycle;
    ai._lifecycleSub = lifecycleSub;

    if (config.warmUpOnInitialize) {
      // Deliberately not awaited: `initialize` stays fast and the app can
      // render while the models load. Progress is on
      // `ai.runtime.loadProgress(id)`; failures surface there and on the
      // first real call, so nothing is swallowed silently.
      unawaited(ai.warmUp());
    }
    return ai;
  }

  /// Backwards-compatible alias for [initialize].
  static Future<LocalAI> create(
    LocalAIConfig config, {
    List<AdapterPlugin> plugins = const [],
    bool enableAudio = true,
  }) =>
      initialize(config, plugins: plugins, enableAudio: enableAudio);

  AppLifecycleObserver? _lifecycle;
  StreamSubscription<AppLifecyclePhase>? _lifecycleSub;

  /// Releases runtime, download, audio and lifecycle resources.
  Future<void> dispose() async {
    await _lifecycleSub?.cancel();
    _lifecycle?.dispose();
    await _audioSource?.stop();
    await _audioOutput?.stop();
    await _scheduler.dispose();
    await _manager.dispose();
  }
}
