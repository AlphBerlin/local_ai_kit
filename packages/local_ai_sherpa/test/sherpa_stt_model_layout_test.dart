import 'package:local_ai_sherpa/local_ai_sherpa.dart';
import 'package:test/test.dart';

void main() {
  group('Sherpa STT model layout detection', () {
    test('recognizes Dolphin CTC model ids', () {
      expect(
        sherpaSttModelKindForId(
          'sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02',
        ),
        SherpaSttModelKind.dolphin,
      );
    });

    test('recognizes Moonshine v2 model ids separately from v1', () {
      expect(
        sherpaSttModelKindForId(
          'sherpa-onnx-moonshine-base-ja-quantized-2026-02-27',
        ),
        SherpaSttModelKind.moonshineV2,
      );
      expect(
        sherpaSttModelKindForId('sherpa-onnx-moonshine-tiny-en'),
        SherpaSttModelKind.moonshineV1,
      );
    });

    test('leaves unrelated model ids on automatic detection', () {
      expect(
        sherpaSttModelKindForId('sherpa-onnx-sense-voice-zh-en-ja-ko-yue'),
        SherpaSttModelKind.auto,
      );
    });
  });
}
