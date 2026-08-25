/// Per-component configuration models (architecture §4.3).
library;

import '../runtime/memory_policy.dart';

/// LLM component configuration.
class LlmConfig {
  const LlmConfig({
    required this.modelId,
    this.runtime = RuntimePreference.auto,
    this.maxContextTokens,
    this.temperature = 0.8,
    this.enableGenkit = false,
  });

  /// References a `LocalModelManifest.id` from the catalog.
  final String modelId;

  /// Preferred execution backend.
  final RuntimePreference runtime;

  /// Context window cap; `null` = model default.
  final int? maxContextTokens;

  /// Default sampling temperature.
  final double temperature;

  /// Whether to wrap the LLM with the Genkit orchestration layer
  /// (requires the `local_ai_genkit` package and its plugin).
  final bool enableGenkit;
}

/// STT component configuration.
class SttConfig {
  const SttConfig({
    required this.modelId,
    this.language,
    this.enablePunctuation = true,
  });

  final String modelId;
  final String? language;
  final bool enablePunctuation;
}

/// TTS component configuration.
class TtsConfig {
  const TtsConfig({
    required this.modelId,
    this.voiceId,
    this.speed = 1.0,
  });

  final String modelId;
  final String? voiceId;
  final double speed;
}

/// VAD component configuration.
class VadConfig {
  const VadConfig({
    required this.modelId,
    this.threshold = 0.5,
    this.minSpeechDurationMs = 150,
    this.minSilenceDurationMs = 350,
    this.sampleRate = 16000,
  });

  final String modelId;

  /// Speech probability threshold in [0, 1].
  final double threshold;

  /// Speech shorter than this is discarded as noise.
  final int minSpeechDurationMs;

  /// Silence longer than this ends an utterance.
  final int minSilenceDurationMs;

  /// Expected input sample rate.
  final int sampleRate;

  /// Copy used by the voice pipeline to raise the threshold while TTS is
  /// playing (echo false-trigger mitigation without AEC, architecture §7.6).
  VadConfig copyWithThreshold(double newThreshold) => VadConfig(
        modelId: modelId,
        threshold: newThreshold,
        minSpeechDurationMs: minSpeechDurationMs,
        minSilenceDurationMs: minSilenceDurationMs,
        sampleRate: sampleRate,
      );
}

/// Embedding component configuration.
class EmbeddingConfig {
  const EmbeddingConfig({required this.modelId, this.dimensions});

  final String modelId;
  final int? dimensions;
}
