import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

void main() {
  test('picks the only gguf file', () {
    expect(
      GgufLocator.select(['installed.json', 'model.gguf', 'README.md']),
      'model.gguf',
    );
  });

  test('never picks a multimodal projector as the model', () {
    expect(
      GgufLocator.select(['mmproj-model-f16.gguf', 'model.gguf']),
      'model.gguf',
    );
    expect(GgufLocator.select(['mmproj-model-f16.gguf']), isNull);
  });

  test('exposes the projector separately', () {
    expect(
      GgufLocator.selectProjector(['mmproj-f16.gguf', 'model.gguf']),
      'mmproj-f16.gguf',
    );
    expect(GgufLocator.selectProjector(['model.gguf']), isNull);
  });

  test('picks the first shard of a sharded model', () {
    expect(
      GgufLocator.select([
        'big-00002-of-00003.gguf',
        'big-00001-of-00003.gguf',
        'big-00003-of-00003.gguf',
      ]),
      'big-00001-of-00003.gguf',
    );
  });

  test('refuses a shard set whose first shard is missing', () {
    expect(
      GgufLocator.select(
          ['big-00002-of-00003.gguf', 'big-00003-of-00003.gguf']),
      isNull,
    );
  });

  test('is deterministic when several unrelated gguf files are present', () {
    expect(GgufLocator.select(['b.gguf', 'a.gguf']), 'a.gguf');
    expect(GgufLocator.select(['a.gguf', 'b.gguf']), 'a.gguf');
  });

  test('returns null when nothing is a gguf', () {
    expect(GgufLocator.select(['model.onnx', 'weights.bin']), isNull);
    expect(GgufLocator.select(const []), isNull);
  });

  test('extension matching is case-insensitive', () {
    expect(GgufLocator.select(['Model.GGUF']), 'Model.GGUF');
  });
}
