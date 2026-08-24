/// On-device embedding capability interface.
library;

import 'dart:async';
/// Options for [LocalEmbedding.load].
class EmbeddingLoadOptions {
  const EmbeddingLoadOptions({
    required this.modelId,
    this.dimensions,
  });

  /// Catalog id of the embedding model.
  final String modelId;

  /// Requested output dimensions when the model supports truncation.
  final int? dimensions;
}

/// On-device text embeddings (for RAG / semantic search).
abstract interface class LocalEmbedding {
  /// Loads the embedding model.
  Future<void> load(EmbeddingLoadOptions options);

  /// Releases the model.
  Future<void> unload();

  /// Embeds a single [text].
  Future<List<double>> embed(String text);

  /// Embeds a batch; implementations may pipeline internally.
  Future<List<List<double>>> embedBatch(List<String> texts);
}