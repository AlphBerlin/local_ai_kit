import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as fg;
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';

void main() {
  group('GemmaLlmAdapter model file type mapping', () {
    test('maps LiteRT-LM weights to the LiteRT-LM runtime format', () {
      expect(
        GemmaLlmAdapter.modelFileTypeForPath('Qwen3.5-0.8B_int8.litertlm'),
        fg.ModelFileType.litertlm,
      );
    });

    test('keeps task and binary weights on their native formats', () {
      expect(
        GemmaLlmAdapter.modelFileTypeForPath('qwen.task'),
        fg.ModelFileType.task,
      );
      expect(
        GemmaLlmAdapter.modelFileTypeForPath('model.bin'),
        fg.ModelFileType.binary,
      );
    });
  });

  test('maps only text responses at the typed runtime boundary', () {
    expect(
      GemmaLlmAdapter.textTokenForResponse(const fg.TextResponse('hello')),
      'hello',
    );
    expect(
      GemmaLlmAdapter.textTokenForResponse(const fg.ThinkingResponse('hmm')),
      isNull,
    );
  });

  test('per-request generation settings reach the native LiteRT session', () {
    final config = GemmaGenerationConfig.resolve(
      LlmRequest.prompt(
        'hello',
        temperature: 0.35,
        maxTokens: 64,
      ).copyWith(topP: 0.75),
      const LlmLoadOptions(
        modelId: 'qwen-3.5-0.8b-instruct',
        temperature: 0.8,
        topK: 32,
        topP: 0.9,
      ),
    );

    expect(config.temperature, 0.35);
    expect(config.topK, 32);
    expect(config.topP, 0.75);
    expect(config.maxOutputTokens, 64);
  });

  test('Qwen 3.5 uses its published non-thinking text sampler defaults', () {
    final config = GemmaGenerationConfig.resolve(
      LlmRequest.prompt('What does o genki desuka mean?'),
      const LlmLoadOptions(modelId: 'qwen-3.5-0.8b-instruct'),
    );

    expect(config.temperature, 1.0);
    expect(config.topK, 20);
    expect(config.topP, 1.0);
  });
}
