/// User-facing capability facades. Thin delegates: ensure-installed →
/// ensure-loaded (via the runtime scheduler) → call the shared adapter.
library;

import 'dart:async';
import 'package:local_ai_core/local_ai_core.dart';

import '../download/model_manager_impl.dart';
import '../runtime/runtime_scheduler.dart';

/// Shared ensure-ready helper for all capability facades.
class _CapabilityGate {
  _CapabilityGate({
    required this.models,
    required this.runtime,
  });

  final ModelManagerImpl models;
  final RuntimeScheduler runtime;

  /// Ensures the model of [configModelId] is installed and loaded, then
  /// returns its adapter.
  Future<T> ready<T>(
    String configModelId,
    RuntimePreference preference,
    String capabilityName,
  ) async {
    await models.ensureInstalled(configModelId);
    if (!runtime.isLoaded(configModelId)) {
      await runtime.loadModel(configModelId, preference: preference);
    }
    runtime.touch(configModelId);
    try {
      return runtime.adapter<T>(configModelId);
    } on Object {
      throw InvalidStateError(
          'No adapter instance for $capabilityName model "$configModelId". '
          'Did you register the matching AdapterPlugin?');
    }
  }
}

/// `ai.llm` facade.
class LocalLlmFacade {
  LocalLlmFacade({
    required LlmConfig? config,
    required RuntimePreference defaultPreference,
    required ModelManagerImpl models,
    required RuntimeScheduler runtime,
  })  : _config = config,
        _defaultPreference = defaultPreference,
        _gate = _CapabilityGate(models: models, runtime: runtime);

  final LlmConfig? _config;
  final RuntimePreference _defaultPreference;
  final _CapabilityGate _gate;

  LlmConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw const InvalidStateError(
          'LLM is not configured: pass LocalAIConfig(llm: ...).');
    }
    return config;
  }

  Future<LocalLlm> _ready() async {
    final config = _requireConfig();
    return _gate.ready<LocalLlm>(
        config.modelId,
        config.runtime == RuntimePreference.auto
            ? _defaultPreference
            : config.runtime,
        'llm');
  }

  /// Ensures the LLM model is downloaded and loaded, returning the underlying adapter.
  Future<LocalLlm> ready() => _ready();

  /// Whether the configured LLM is currently loaded in memory.
  bool get isLoaded =>
      _config != null && _gate.runtime.isLoaded(_config.modelId);

  /// Streams a completion for [request].
  Future<Stream<LlmChunk>> generateStream(LlmRequest request) async =>
      (await _ready()).generateStream(request);

  /// One-shot generation from a plain [prompt].
  Future<LlmResponse> generate(
    String prompt, {
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    JsonSchema? responseSchema,
  }) async {
    final llm = await _ready();
    final config = _requireConfig();
    return llm.generate(LlmRequest.prompt(
      prompt,
      systemPrompt: systemPrompt,
      temperature: temperature ?? config.temperature,
      maxTokens: maxTokens,
      responseSchema: responseSchema,
    ));
  }

  /// Schema-validated structured output with retries.
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  }) async {
    final llm = await _ready();
    return llm.generateStructured(prompt,
        schema: schema, fromJson: fromJson, maxRetries: maxRetries);
  }

  /// Unloads the LLM from memory (it reloads lazily on next use).
  Future<void> unload() => _gate.runtime.unloadModel(_requireConfig().modelId);
}

/// `ai.stt` facade.
class LocalSttFacade {
  LocalSttFacade({
    required SttConfig? config,
    required ModelManagerImpl models,
    required RuntimeScheduler runtime,
  })  : _config = config,
        _gate = _CapabilityGate(models: models, runtime: runtime);

  final SttConfig? _config;
  final _CapabilityGate _gate;

  SttConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw const InvalidStateError(
          'STT is not configured: pass LocalAIConfig(stt: ...).');
    }
    return config;
  }

  Future<LocalStt> _ready() async {
    final config = _requireConfig();
    return _gate.ready<LocalStt>(config.modelId, RuntimePreference.auto, 'stt');
  }

  /// Streams transcription events for a live [audio] frame stream.
  Future<Stream<TranscriptEvent>> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) async =>
      (await _ready()).transcribeStream(audio, options: options);

  /// One-shot transcription of a complete [audio] buffer.
  Future<Transcript> transcribe(AudioBuffer audio,
          {SttOptions? options}) async =>
      (await _ready()).transcribe(audio, options: options);
}

/// `ai.tts` facade.
class LocalTtsFacade {
  LocalTtsFacade({
    required TtsConfig? config,
    required ModelManagerImpl models,
    required RuntimeScheduler runtime,
    required LocalAudioOutput? audioOutput,
  })  : _config = config,
        _audioOutput = audioOutput,
        _gate = _CapabilityGate(models: models, runtime: runtime);

  final TtsConfig? _config;
  final LocalAudioOutput? _audioOutput;
  final _CapabilityGate _gate;

  TtsConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw const InvalidStateError(
          'TTS is not configured: pass LocalAIConfig(tts: ...).');
    }
    return config;
  }

  Future<LocalTts> _ready() async {
    final config = _requireConfig();
    return _gate.ready<LocalTts>(config.modelId, RuntimePreference.auto, 'tts');
  }

  /// Voices installed on device for the configured TTS model.
  Future<List<LocalVoice>> voices() async => (await _ready()).installedVoices;

  /// Downloads a voice for the configured TTS model.
  Future<void> installVoice(String voiceId, {DownloadPolicy? policy}) async {
    final config = _requireConfig();
    await _gate.models.installVoice(voiceId,
        ttsModelId: config.modelId, policy: policy ?? const DownloadPolicy());
  }

  /// Streams synthesized audio for [text] (does not play it).
  Future<Stream<AudioChunk>> synthesizeStream(
    String text, {
    String? voiceId,
    String? language,
    double? speed,
    double? pitch,
  }) async {
    final config = _requireConfig();
    return (await _ready()).synthesizeStream(SpeakRequest(
      text: text,
      voiceId: voiceId ?? config.voiceId,
      language: language,
      speed: speed ?? config.speed,
      pitch: pitch ?? 1.0,
    ));
  }

  /// Speaks [text] through the configured [LocalAudioOutput].
  Future<void> speak(
    String text, {
    String? voiceId,
    String? language,
    double? speed,
    double? pitch,
  }) async {
    final output = _audioOutput;
    if (output == null) {
      throw const InvalidStateError(
          'No LocalAudioOutput configured: enable audio output in '
          'LocalAI.initialize.');
    }
    final chunks = await synthesizeStream(
      text,
      voiceId: voiceId,
      language: language,
      speed: speed,
      pitch: pitch,
    );
    await output.play(chunks);
  }

  /// Immediately truncates playback (barge-in support).
  Future<void> stopSpeaking() => _audioOutput?.stop() ?? Future.value();
}
