import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

double norm(List<double> v) =>
    math.sqrt(v.fold<double>(0, (sum, x) => sum + x * x));

void main() {
  test('truncation shortens and re-normalises', () {
    final truncated = EmbeddingVectors.truncate([3, 4, 12, 0], 2);
    expect(truncated.length, 2);
    expect(norm(truncated), closeTo(1.0, 1e-12));
    expect(truncated[0] / truncated[1], closeTo(3 / 4, 1e-12));
  });

  test('a no-op width leaves the vector untouched', () {
    const vector = [1.0, 2.0, 3.0];
    expect(EmbeddingVectors.truncate(vector, null), same(vector));
    expect(EmbeddingVectors.truncate(vector, 0), same(vector));
    expect(EmbeddingVectors.truncate(vector, 3), same(vector));
    expect(EmbeddingVectors.truncate(vector, 8), same(vector));
  });

  test('normalising a zero vector does not divide by zero', () {
    expect(EmbeddingVectors.normalize([0, 0, 0]), [0, 0, 0]);
  });

  test('cosine similarity is 1 for identical and 0 for orthogonal vectors',
      () {
    expect(EmbeddingVectors.cosineSimilarity([1, 2, 3], [1, 2, 3]),
        closeTo(1.0, 1e-12));
    expect(EmbeddingVectors.cosineSimilarity([1, 0], [0, 1]), 0);
    expect(EmbeddingVectors.cosineSimilarity([1, 0], [-1, 0]),
        closeTo(-1.0, 1e-12));
  });

  test('mismatched or empty vectors score zero instead of throwing', () {
    expect(EmbeddingVectors.cosineSimilarity([1, 2], [1, 2, 3]), 0);
    expect(EmbeddingVectors.cosineSimilarity(const [], const []), 0);
    expect(EmbeddingVectors.cosineSimilarity([0, 0], [1, 1]), 0);
  });
}
