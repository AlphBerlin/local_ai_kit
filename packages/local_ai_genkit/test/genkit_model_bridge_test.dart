import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' as gk;
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_genkit/local_ai_genkit.dart';

void main() {
  test('registers a LocalLlm as a Genkit model with streaming chunks',
      () async {
    final inner = FakeLlm(responseText: 'hello world', chunkSize: 5);
    await inner.load(const LlmLoadOptions(modelId: 'test-model'));
    final adapter = GenkitLlmAdapter(inner: inner);
    final genkit = gk.Genkit(promptDir: null);

    final model = adapter.registerAsGenkitModel(genkit: genkit);
    final chunks = <gk.ModelResponseChunk>[];
    final response = await model.call(
      gk.ModelRequest(
        messages: [
          gk.Message(role: gk.Role.system, content: [
            gk.TextPart(text: 'Be concise.'),
          ]),
          gk.Message(role: gk.Role.user, content: [
            gk.TextPart(text: 'Say hello.'),
          ]),
        ],
        config: {'temperature': 0.2, 'maxOutputTokens': 32},
      ),
      onChunk: chunks.add,
    );

    expect(model.name, 'localai/inner');
    expect(
      chunks.map((chunk) => chunk.content.single.toJson()['text']),
      ['hello', ' worl', 'd'],
    );
    expect(
      response.message!.content.single.toJson()['text'],
      'hello world',
    );
    expect(response.finishReason, gk.FinishReason.stop);
  });
}
