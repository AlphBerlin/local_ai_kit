/// Model catalog interface + model packs (architecture §4.2, §5.5).
library;

import 'dart:async';
import '../models/manifest.dart';

/// A curated bundle of models installed together (e.g. "voice assistant
/// starter pack" = VAD + STT + LLM + TTS).
class ModelPack {
  const ModelPack({
    required this.id,
    required this.name,
    required this.description,
    required this.modelIds,
  });

  final String id;
  final String name;
  final String description;
  final List<String> modelIds;
}

/// Read access to the merged model catalog (built-in + remote).
///
/// Implemented by `ModelCatalogService` in `local_ai_kit`.
abstract interface class LocalModelCatalog {
  /// Lists manifests, optionally filtered.
  Future<List<LocalModelManifest>> list({ModelType? type, String? language});

  /// Returns the manifest for [modelId]; throws `ModelNotFoundError` when
  /// unknown.
  Future<LocalModelManifest> get(String modelId);

  /// Pulls the remote catalog, merges by `catalogVersion` and persists the
  /// merged result. Falls back to the cached remote catalog, then to the
  /// built-in one, when the network is unavailable.
  Future<void> refresh();

  /// Curated packs available for one-tap install.
  List<ModelPack> get packs;

  /// Installs every model of [packId] (`ensureInstalled` semantics).
  Future<void> installPack(String packId);
}
