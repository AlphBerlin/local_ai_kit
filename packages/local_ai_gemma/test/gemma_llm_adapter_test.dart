import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as fg;
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
}
