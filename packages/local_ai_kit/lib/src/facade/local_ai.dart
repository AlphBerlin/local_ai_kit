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
    required VoiceSessionFactory voiceFactory,
    required LocalAudioSource? audioSource,
    required LocalAudioOutput? audioOutput,
  })  : _registry = registry,
        _catalog = catalog,
        _scheduler = scheduler,
        _llmFacade = llmFacade,
        _sttFacade = sttFacade,
        _ttsFacade = ttsFacade,
        _voiceFactory = voiceFactory,
        _audioSource = audioSource,
        _audioOutput = audioOutput,
        models = ModelHub(manager: manager, catalog: catalog);

  /// The active configuration.
  final LocalAIConfig config;

  final AdapterRegistry _registry;
  final ModelCatalogService _catalog;
  final RuntimeScheduler _scheduler;
  final LocalLlmFacade _llmFacade;
  final LocalSttFacade _sttFacade;
  final LocalTtsFacade _ttsFacade;
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

  /// Starts the typed pipeline DSL (architecture §5.4).
  LocalPipeline pipeline() => LocalPipeline(this);

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------

  /// Assembles the kit: storage → registry (+plugins) → catalog refresh →
  /// model manager crash recovery → runtime scheduler → facades.
  static Future<LocalAI> initialize(
    LocalAIConfig config, {
    List<AdapterPlugin> plugins = const [],
    bool enableAudio = true,
    LocalStoragePaths? paths,
    NetworkPolicy? networkPolicy,
    Future<DeviceCapabilities> Function()? deviceProbe,
    FreeDiskProbe? freeDiskProbe,
  }) async {
    final resolvedPaths = paths ?? await FlutterStoragePaths.resolve();
    await resolvedPaths.ensureInitialized();
    final resolvedNetwork = networkPolicy ?? FlutterNetworkPolicy();

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
      freeDiskProbe: freeDiskProbe,
    );
    await manager.initialize();

    final scheduler = RuntimeScheduler(
      catalog: catalog,
      registry: registry,
      policy: config.memoryPolicy,
      deviceProbe: deviceProbe,
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
      voiceFactory: voiceFactory,
      audioSource: audioSource,
      audioOutput: audioOutput,
    );
    ai._lifecycle = lifecycle;
    ai._lifecycleSub = lifecycleSub;
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

  /// Releases runtime, audio and lifecycle resources.
  Future<void> dispose() async {
    await _lifecycleSub?.cancel();
    _lifecycle?.dispose();
    await _audioSource?.stop();
    await _audioOutput?.stop();
    await _scheduler.dispose();
  }
}
