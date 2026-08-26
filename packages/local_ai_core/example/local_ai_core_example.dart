// ignore_for_file: avoid_print
import 'package:local_ai_core/local_ai_core.dart';

/// Minimal end-to-end usage of `local_ai_core`'s pure-Dart contracts.
///
/// This wires up the built-in [FakeLlm] test double against the same
/// [LocalLlm] interface a real adapter (llama.cpp, MediaPipe, ...) would
/// implement, so the shape below is representative of production code.
Future<void> main() async {
  // A preset config selects sensible defaults for a given use case.
  final config = LocalAIConfig.offlineChat();
  print('Configured LLM model: ${config.llm?.modelId}');

  // In production this would be a real adapter resolved through
  // AdapterRegistry; FakeLlm lets this example run with zero native deps.
  final llm = FakeLlm(responseText: 'Hello from LocalAI Kit!');
  await llm.load(const LlmLoadOptions(modelId: 'gemma-3n-e2b-it-int4'));

  final request = LlmRequest.prompt(
    'Say hello in one short sentence.',
    systemPrompt: 'You are a concise assistant.',
  );

  final buffer = StringBuffer();
  await for (final chunk in llm.generateStream(request)) {
    buffer.write(chunk.textDelta);
    if (chunk.isFinal) {
      print('Final response: $buffer');
    }
  }

  await llm.unload();
}
