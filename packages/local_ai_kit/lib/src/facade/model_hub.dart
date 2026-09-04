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

  /// Registers an app-supplied model file (bring-your-own GGUF, MDM push,
  /// file picker result) as an installed model without downloading or
  /// verifying it.
  ///
  /// ```dart
  /// await ai.models.registerExternalModel(
  ///   const LocalModelManifest(
  ///     id: 'my-gguf',
  ///     type: ModelType.llm,
  ///     provider: ModelProviders.llamaCpp,
  ///     delivery: ModelDelivery.external,
  ///     files: [ModelFile(name: 'my.gguf', url: '', sha256: '', sizeBytes: 0)],
  ///   ),
  ///   localFilePath: pickedFile.path,
  /// );
  /// ```
  ///
  /// See `ModelManagerImpl.registerExternalModel` for the linking rules and
  /// the (deliberate) absence of an integrity check.
  Future<void> registerExternalModel(
    LocalModelManifest manifest, {
    required String localFilePath,
  }) =>
      _manager.registerExternalModel(manifest, localFilePath: localFilePath);

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

  // ---------------------------------------------------------------------------
  // Compatibility — check before you offer the download
  // ---------------------------------------------------------------------------

  /// Whether this device can run [modelId], checked **before** downloading.
  ///
  /// ```dart
  /// final report = await ai.models.checkCompatibility('gemma-3n-e2b-it-int4');
  /// if (!report.isCompatible) {
  ///   showBlocked(report.summary);          // e.g. not enough free disk
  /// } else {
  ///   if (report.hasWarnings) showTight(report.warnings);
  ///   await ai.models.ensureInstalled('gemma-3n-e2b-it-int4');
  /// }
  /// ```
  ///
  /// `install` / `ensureInstalled` run the same check themselves and throw
  /// `IncompatibleDeviceError` on a blocking issue (unless the config sets
  /// `compatibilityEnforcement` to something other than
  /// `CompatibilityEnforcement.enforce`), so this is for building the UI,
  /// not for safety.
  Future<CompatibilityReport> checkCompatibility(String modelId) =>
      _manager.checkCompatibility(modelId);

  /// Catalog models this device can actually run, each with its report.
  ///
  /// Use it to build a "models you can install" screen: hide or annotate
  /// the entries whose report is incompatible instead of letting a user
  /// spend a gigabyte of mobile data on a model that cannot load.
  Future<List<ModelCompatibility>> compatible({
    ModelType? type,
    String? language,
    bool includeIncompatible = false,
  }) async {
    final manifests = await _catalog.list(type: type, language: language);
    final results = <ModelCompatibility>[];
    for (final manifest in manifests) {
      final report = await _manager.checkManifestCompatibility(manifest);
      if (!report.isCompatible && !includeIncompatible) continue;
      results.add(ModelCompatibility(manifest: manifest, report: report));
    }
    return results;
  }

  /// Refreshes the remote catalog and merges it into the built-in one.
  Future<void> refreshCatalog() => _catalog.refresh();

  /// Ids of installed models with a newer catalog version available.
  Set<String> get updatable => _catalog.updatable;
}

/// A catalog entry paired with its compatibility verdict for this device.
class ModelCompatibility {
  const ModelCompatibility({required this.manifest, required this.report});

  final LocalModelManifest manifest;
  final CompatibilityReport report;

  bool get isCompatible => report.isCompatible;
  bool get hasWarnings => report.hasWarnings;

  @override
  String toString() => 'ModelCompatibility(${manifest.id}, ${report.summary})';
}
