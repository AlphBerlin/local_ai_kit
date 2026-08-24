/// Genkit model-provider bridge: wraps any core [LocalLlm] as a
/// genkit-compatible model and re-exposes it as [LocalLlm].
library;

import 'dart:async';
import 'package:local_ai_core/local_ai_core.dart';

import 'genkit_orchestrator.dart';

/// Decorates an inner [LocalLlm] with Genkit orchestration while still
/// satisfying the core interface, so it can be registered back into the
/// [AdapterRegistry] as the effective LLM.
///
/// TODO(verify): genkit Dart API — the bridge to a real genkit
/// `ModelProvider` (defineModel / generate delegates) is sketched in
/// [registerAsGenkitModel]; the upstream API for custom model providers is
/// still evolving.
class GenkitLlmAdapter
    with StructuredOutputSupport
    implements LocalLlm, OrchestratorProvider {
  GenkitLlmAdapter({required LocalLlm inner})
      : orchestrator = GenkitOrchestrator(inner: inner);

  /// Orchestration layer over the inner LLM (flows/tools/templates).
  @override
  final GenkitOrchestrator orchestrator;

  LocalLlm get _inner => orchestrator.inner;

  /// Escape hatch used by `LocalAIGenkitX.genkit` (architecture §3.5).
  GenkitOrchestrator get genkit => orchestrator;

  @override
  Future<void> load(LlmLoadOptions options) => _inner.load(options);

  @override
  Future<void> unload() => _inner.unload();

  @override
  bool get isLoaded => _inner.isLoaded;

  @override
  Stream<LlmChunk> generateStream(LlmRequest request) =>
      _inner.generateStream(request);

  @override
  Future<LlmResponse> generate(LlmRequest request) => _inner.generate(request);

  /// Sketch of a real genkit model provider registration.
  ///
  /// TODO(verify): genkit API — defineModel({name, ...}, generateDelegate)
  /// mapping GenerateRequest → LlmRequest and streamed chunks back.
  void registerAsGenkitModel() {
    // import 'package:genkit/genkit.dart';
    // Genkit().defineModel(
    //   name: 'localai/inner',
    //   fn: (request, streaming) async {
    //     final llmRequest = _mapRequest(request);
    //     if (streaming != null) {
    //       await for (final chunk in generateStream(llmRequest)) {
    //         streaming(chunk.textDelta);
    //       }
    //       return _emptyResponse;
    //     }
    //     final response = await generate(llmRequest);
    //     return _mapResponse(response);
    //   },
    // );
  }
}