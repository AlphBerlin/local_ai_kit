/// Genkit model-provider bridge: wraps any core [LocalLlm] as a
/// genkit-compatible model and re-exposes it as [LocalLlm].
library;

import 'dart:async';

import 'package:genkit/genkit.dart' as gk;
import 'package:local_ai_core/local_ai_core.dart';

import 'genkit_orchestrator.dart';

/// Decorates an inner [LocalLlm] with Genkit orchestration while still
/// satisfying the core interface, so it can be registered back into the
/// [AdapterRegistry] as the effective LLM.
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

  /// Registers this adapter with a caller-owned Genkit runtime.
  gk.Model<void> registerAsGenkitModel({
    required gk.Genkit genkit,
    String name = 'localai/inner',
  }) {
    return genkit.defineModel(
      name: name,
      fn: (request, context) async {
        final llmRequest = _mapRequest(request);
        final response = context.streamingRequested
            ? await LlmResponse.fold(
                _streamToGenkit(llmRequest, context),
              )
            : await generate(llmRequest);
        return _mapResponse(response);
      },
    );
  }

  Stream<LlmChunk> _streamToGenkit(
    LlmRequest request,
    gk.ActionFnArg<gk.ModelResponseChunk, gk.ModelRequest, void> context,
  ) async* {
    await for (final chunk in generateStream(request)) {
      if (chunk.textDelta.isNotEmpty) {
        context.sendChunk(gk.ModelResponseChunk(
          role: gk.Role.model,
          content: [gk.TextPart(text: chunk.textDelta)],
        ));
      }
      yield chunk;
    }
  }

  static LlmRequest _mapRequest(gk.ModelRequest request) {
    final config = request.config ?? const <String, dynamic>{};
    final outputSchema = request.output?.schema;
    return LlmRequest(
      messages: request.messages.map(_mapMessage).toList(growable: false),
      temperature: (config['temperature'] as num?)?.toDouble(),
      maxTokens: (config['maxOutputTokens'] ?? config['maxTokens']) is num
          ? ((config['maxOutputTokens'] ?? config['maxTokens']) as num).toInt()
          : null,
      topP: (config['topP'] as num?)?.toDouble(),
      stopSequences: config['stopSequences'] is List
          ? (config['stopSequences'] as List).whereType<String>().toList()
          : const [],
      responseSchema: outputSchema == null
          ? null
          : JsonSchema.fromMap(outputSchema.cast<String, Object?>()),
    );
  }

  static LlmMessage _mapMessage(gk.Message message) {
    final content = message.content;
    final text = content.map(_textPart).join();
    return LlmMessage(
      role: switch (message.role.value) {
        'system' => LlmRole.system,
        'model' => LlmRole.assistant,
        _ => LlmRole.user,
      },
      content: text,
    );
  }

  static String _textPart(gk.Part part) {
    if (part is gk.TextPart) return part.text;
    // Genkit's generated Part union currently deserializes through the base
    // Part factory, so identify a text part by its stable JSON field as well.
    final text = part.toJson()['text'];
    if (text is String) return text;
    throw UnsupportedError(
      'LocalAI Genkit bridge supports text message parts only.',
    );
  }

  static gk.ModelResponse _mapResponse(LlmResponse response) {
    return gk.ModelResponse(
      message: gk.Message(
        role: gk.Role.model,
        content: [gk.TextPart(text: response.text)],
      ),
      finishReason: switch (response.finishReason) {
        LlmFinishReason.stop => gk.FinishReason.stop,
        LlmFinishReason.length => gk.FinishReason.length,
        LlmFinishReason.cancelled => gk.FinishReason.interrupted,
        LlmFinishReason.contentFiltered => gk.FinishReason.blocked,
        LlmFinishReason.error => gk.FinishReason.other,
      },
    );
  }
}
