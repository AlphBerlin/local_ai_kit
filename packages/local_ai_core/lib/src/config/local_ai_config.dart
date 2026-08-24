/// Top-level kit configuration with presets (architecture §4.3).
library;

import '../models/model_delivery.dart';
import '../models/models.dart';
import '../runtime/memory_policy.dart';
import 'component_configs.dart';

/// Root configuration handed to `LocalAI.initialize`.
///
/// Every component is optional: `null` means the capability is not wired
/// and its facade will throw `InvalidStateError` on use.
class LocalAIConfig {
  const LocalAIConfig({
    this.llm,
    this.vad,
    this.stt,
    this.tts,
    this.embedding,
    this.deliveryPolicy = const ModelDeliveryPolicy.smart(),
    this.memoryPolicy = const RuntimeMemoryPolicy(),
    this.runtimePreference = RuntimePreference.auto,
    this.remoteCatalogUrl,
  });

  /// Preset: small models, aggressive unloading, CPU-only. For low-RAM
  /// devices.
  factory LocalAIConfig.lowMemory() => const LocalAIConfig(
        llm: LlmConfig(
          modelId: 'gemma-3n-e2b-it-int4',
          runtime: RuntimePreference.cpu,
          maxContextTokens: 4096,
        ),
        memoryPolicy: RuntimeMemoryPolicy.lowMemory(),
        runtimePreference: RuntimePreference.cpu,
      );

  /// Preset: full voice assistant stack (VAD + STT + LLM + TTS).
  factory LocalAIConfig.voiceAssistant() => const LocalAIConfig(
        llm: LlmConfig(modelId: 'gemma-3n-e2b-it-int4'),
        vad: VadConfig(modelId: 'silero-vad'),
        stt: SttConfig(
          modelId: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
        ),
        tts: TtsConfig(
          modelId: 'supertonic-tts',
          voiceId: 'supertonic-en-female-1',
        ),
      );

  /// Preset: offline text chat only, LLM bundled when small enough.
  factory LocalAIConfig.offlineChat() => const LocalAIConfig(
        llm: LlmConfig(modelId: 'gemma-3n-e2b-it-int4'),
        deliveryPolicy: ModelDeliveryPolicy.smart(bundleBelowMB: 25),
      );

  /// Preset: transcription only (VAD + STT, no LLM/TTS).
  factory LocalAIConfig.transcription() => const LocalAIConfig(
        vad: VadConfig(modelId: 'silero-vad'),
        stt: SttConfig(
          modelId: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
        ),
      );

  final LlmConfig? llm;
  final VadConfig? vad;
  final SttConfig? stt;
  final TtsConfig? tts;
  final EmbeddingConfig? embedding;

  /// How models reach the device.
  final ModelDeliveryPolicy deliveryPolicy;

  /// Runtime memory scheduling policy.
  final RuntimeMemoryPolicy memoryPolicy;

  /// Default backend preference for all components.
  final RuntimePreference runtimePreference;

  /// Optional remote catalog endpoint (HTTPS JSON, architecture §5.5).
  final Uri? remoteCatalogUrl;

  LocalAIConfig copyWith({
    LlmConfig? llm,
    VadConfig? vad,
    SttConfig? stt,
    TtsConfig? tts,
    EmbeddingConfig? embedding,
    ModelDeliveryPolicy? deliveryPolicy,
    RuntimeMemoryPolicy? memoryPolicy,
    RuntimePreference? runtimePreference,
    Uri? remoteCatalogUrl,
  }) {
    return LocalAIConfig(
      llm: llm ?? this.llm,
      vad: vad ?? this.vad,
      stt: stt ?? this.stt,
      tts: tts ?? this.tts,
      embedding: embedding ?? this.embedding,
      deliveryPolicy: deliveryPolicy ?? this.deliveryPolicy,
      memoryPolicy: memoryPolicy ?? this.memoryPolicy,
      runtimePreference: runtimePreference ?? this.runtimePreference,
      remoteCatalogUrl: remoteCatalogUrl ?? this.remoteCatalogUrl,
    );
  }
}
