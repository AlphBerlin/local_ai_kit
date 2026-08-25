/// On-device LLM capability interface.
library;

import 'dart:async';
import '../runtime/memory_policy.dart';
import 'json_schema.dart';
import 'llm_request.dart';

/// Options for [LocalLlm.load].
class LlmLoadOptions {
  const LlmLoadOptions({
    required this.modelId,
    this.runtime = RuntimePreference.auto,
    this.maxContextTokens,
    this.temperature = 0.8,
    this.topK = 40,
    this.topP = 0.9,
  });

  /// Catalog id of the model to load (see `LocalModelManifest.id`).
  final String modelId;

  /// Preferred execution backend.
  final RuntimePreference runtime;

  /// Context window cap; `null` = model default. Adapters apply sliding
  /// window truncation to stay within this bound.
  final int? maxContextTokens;

  /// Default sampling temperature for requests that don't override it.
  final double temperature;

  /// Top-k sampling limit.
  final int? topK;

  /// Top-p (nucleus) sampling threshold.
  final double? topP;
}

/// On-device large language model inference.
///
/// Implementations: `GemmaLlmAdapter` (local_ai_gemma), `GenkitLlmAdapter`
/// (local_ai_genkit, orchestration wrapper).
abstract interface class LocalLlm {
  /// Loads the model into memory. Must complete before generation calls.
  Future<void> load(LlmLoadOptions options);

  /// Releases the model and its runtime resources.
  Future<void> unload();

  /// Whether the model is currently loaded and ready.
  bool get isLoaded;

  /// Streams a completion for [request].
  Stream<LlmChunk> generateStream(LlmRequest request);

  /// Non-streaming generation: folds [generateStream].
  Future<LlmResponse> generate(LlmRequest request);

  /// Structured output: injects [schema] into the prompt (or grammar when
  /// the runtime supports constrained decoding), parses the result and
  /// retries up to [maxRetries] times with error feedback before throwing
  /// `StructuredOutputError`.
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  });
}
