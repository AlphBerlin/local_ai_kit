/// `ai.models` facade: catalog + download/install management.
library;

import 'dart:async';
import 'package:local_ai_core/local_ai_core.dart';

import '../catalog/catalog_service.dart';
import '../download/model_manager_impl.dart';

/// Model hub exposed as `ai.models`.
class ModelHub implements LocalModelManager {
  ModelHub({
    required ModelManagerImpl manager,
    required ModelCatalogService catalog,
  })  : _manager = manager,
        _catalog = catalog;

  final ModelManagerImpl _manager;
  final ModelCatalogService _catalog;

  /// Catalog access (list/get/refresh/packs).
  LocalModelCatalog get catalog => _catalog;

  @override
  Future<bool> isInstalled(String modelId) => _manager.isInstalled(modelId);

  @override
  Future<ModelStatus> getStatus(String modelId) => _manager.getStatus(modelId);

  @override
  Future<void> ensureInstalled(String modelId,
          {DownloadPolicy policy = const DownloadPolicy()}) =>
      _manager.ensureInstalled(modelId, policy: policy);

  @override
  Future<void> install(String modelId, {DownloadPolicy? policy}) =>
      _manager.install(modelId, policy: policy);

  @override
  Future<void> update(String modelId) => _manager.update(modelId);

  @override
  Future<void> remove(String modelId) => _manager.remove(modelId);

  @override
  Future<bool> verify(String modelId) => _manager.verify(modelId);

  @override
  Stream<ModelDownloadProgress> downloadProgress(String modelId) =>
      _manager.downloadProgress(modelId);

  @override
  Stream<ModelStatus> watchStatus(String modelId) =>
      _manager.watchStatus(modelId);

  /// Installs a TTS voice (`voices/<voiceId>/`).
  Future<void> installVoice(
    String voiceId, {
    required String ttsModelId,
    DownloadPolicy policy = const DownloadPolicy(),
  }) =>
      _manager.installVoice(voiceId, ttsModelId: ttsModelId, policy: policy);

  /// Installs every model of a curated [ModelPack].
  Future<void> installPack(String packId,
          {DownloadPolicy policy = const DownloadPolicy()}) =>
      _manager.installPack(packId, policy: policy);

  /// Refreshes the remote catalog and merges it into the built-in one.
  Future<void> refreshCatalog() => _catalog.refresh();

  /// Ids of installed models with a newer catalog version available.
  Set<String> get updatable => _catalog.updatable;
}