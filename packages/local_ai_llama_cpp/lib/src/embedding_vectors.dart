/// Pure post-processing for embedding vectors.
library;

import 'dart:math' as math;

/// Vector helpers used by [LlamaCppEmbeddingAdapter].
abstract final class EmbeddingVectors {
  /// Truncates [vector] to [dimensions] and re-normalises it.
  ///
  /// Models trained with Matryoshka representation learning (nomic-embed,
  /// bge-m3, …) keep their most significant components first, so a prefix
  /// is a valid smaller embedding — but only once it is re-normalised to
  /// unit length, otherwise cosine similarity against a full-width vector
  /// is skewed. A `dimensions` that is null, zero, or at least the vector's
  /// own width returns the vector unchanged.
  static List<double> truncate(List<double> vector, int? dimensions) {
    if (dimensions == null ||
        dimensions <= 0 ||
        dimensions >= vector.length) {
      return vector;
    }
    return normalize(vector.sublist(0, dimensions));
  }

  /// L2-normalises [vector]. A zero vector is returned unchanged rather
  /// than divided by zero.
  static List<double> normalize(List<double> vector) {
    var sum = 0.0;
    for (final value in vector) {
      sum += value * value;
    }
    if (sum <= 0) return vector;
    final norm = math.sqrt(sum);
    return <double>[for (final value in vector) value / norm];
  }

  /// Cosine similarity of two equal-length vectors, for callers doing
  /// semantic search on top of [LlamaCppEmbeddingAdapter].
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA <= 0 || normB <= 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}
