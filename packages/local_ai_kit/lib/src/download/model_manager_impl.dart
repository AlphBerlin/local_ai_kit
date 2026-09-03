/// `LocalModelManager` implementation: state machine + streams on top of
/// [DownloadManager] and [ModelInstaller] (architecture §5.1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

import '../catalog/catalog_service.dart';
import 'download_manager.dart';
import 'installer.dart';

/// Concrete model manager wired by `LocalAI.initialize`.
///
/// State machine (single direction, failure may retry):
/// `notInstalled → queued → downloading ⇄ paused → verifying → installing
/// → installed`; `installed → updating → ...` on catalog upgrades;
/// anything may land in `failed`.
class ModelManagerImpl implements LocalModelManager {
  ModelManagerImpl({
    required LocalStoragePaths paths,
    required ModelCatalogService catalog,
    required NetworkPolicy networkPolicy,
    FreeDiskProbe? freeDiskProbe,
    HttpClient? httpClient,
  })  : _paths = paths,
        _catalog = catalog,
        _installer = ModelInstaller(paths: paths),
        _downloader = DownloadManager(
          paths: paths,
          networkPolicy: networkPolicy,
          freeDiskProbe: freeDiskProbe,
          httpClient: httpClient,
        );

  final LocalStoragePaths _paths;
  final ModelCatalogService _catalog;
  final ModelInstaller _installer;
  final DownloadManager _downloader;

  final Map<String, ModelStatus> _statuses = {};
  final Map<String, StreamController<ModelStatus>> _statusControllers = {};
  final Map<String, StreamController<ModelDownloadProgress>>
      _progressControllers = {};
  final Map<String, Future<void>> _inflight = {};
  final Map<String, CancelToken> _cancelTokens = {};

  /// Recovers from a previous crash (half-installed dirs) and warms the
  /// status cache. Called once by `LocalAI.initialize`.
  Future<void> initialize() => _installer.recoverFromCrash();

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  @override
  Future<bool> isInstalled(String modelId) async {
    final manifest = await _catalog.get(modelId);
    return _installer.isInstalled(manifest);
  }

  @override
  Future<ModelStatus> getStatus(String modelId) async {
    final cached = _statuses[modelId];
    if (cached != null &&
        cached.state != ModelInstallState.notInstalled &&
        cached.state != ModelInstallState.failed) {
      return cached;
    }
    final manifest = await _catalog.get(modelId);
    if (_installer.isInstalled(manifest)) {
      final version =
          await _installer.installedVersion(manifest.type, manifest.id);
      // External (bring-your-own) models are never catalog-tracked, so the
      // `catalogVersion: 0` sentinel in their marker must not read as
      // "an update is available".
      final newer = manifest.delivery != ModelDelivery.external &&
          version != null &&
          manifest.catalogVersion > version;
      return _statuses[modelId] = ModelStatus(
        modelId: modelId,
        state: newer ? ModelInstallState.updating : ModelInstallState.installed,
        installedCatalogVersion: version,
      );
    }
    // In-progress download scratch present → report paused (resumable).
    final scratch = Directory(_paths.downloadDir(modelId));
    final resumable = scratch.existsSync() &&
        scratch.listSync().any((e) => e.path.endsWith('.part'));
    return _statuses[modelId] = ModelStatus(
      modelId: modelId,
      state:
          resumable ? ModelInstallState.paused : ModelInstallState.notInstalled,
    );
  }

  @override
  Stream<ModelStatus> watchStatus(String modelId) {
    final controller = _statusControllers.putIfAbsent(
        modelId, () => StreamController<ModelStatus>.broadcast());
    // Emit the current snapshot to new listeners.
    getStatus(modelId).then(controller.add).catchError((Object _) {});
    return controller.stream;
  }

  @override
  Stream<ModelDownloadProgress> downloadProgress(String modelId) {
    final controller = _progressControllers.putIfAbsent(
        modelId, () => StreamController<ModelDownloadProgress>.broadcast());
    return controller.stream;
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  @override
  Future<void> ensureInstalled(
    String modelId, {
    DownloadPolicy policy = const DownloadPolicy(),
  }) async {
    if (await isInstalled(modelId)) {
      final status = await getStatus(modelId);
      if (status.state != ModelInstallState.updating) return;
    }
    return install(modelId, policy: policy);
  }

  @override
  Future<void> install(String modelId, {DownloadPolicy? policy}) {
    // Serialize concurrent installs of the same model behind one Future.
    final existing = _inflight[modelId];
    if (existing != null) return existing;
    final future = _installInternal(modelId, policy ?? const DownloadPolicy())
        .whenComplete(() => _inflight.remove(modelId));
    _inflight[modelId] = future;
    return future;
  }

  Future<void> _installInternal(String modelId, DownloadPolicy policy) async {
    final manifest = await _catalog.get(modelId);
    final cancelToken = _cancelTokens[modelId] = CancelToken();
    try {
      _setStatus(modelId, ModelInstallState.queued);
      final downloadDir = await _downloader.download(
        manifest,
        policy: policy,
        cancelToken: cancelToken,
        onProgress: (progress) {
          _progressControllers[modelId]?.add(progress);
          _setStatus(modelId, progress.state, progress: progress);
        },
      );
      _setStatus(modelId, ModelInstallState.installing);
      await _installer.install(manifest, downloadDir);
      _setStatus(modelId, ModelInstallState.installed,
          installedCatalogVersion: manifest.catalogVersion);
    } on LocalAIError catch (e) {
      _setStatus(modelId, ModelInstallState.failed, error: e);
      rethrow;
    } on Object catch (e, st) {
      final wrapped =
          NativeRuntimeError('install failed', cause: e, stackTrace: st);
      _setStatus(modelId, ModelInstallState.failed, error: wrapped);
      throw wrapped;
    } finally {
      _cancelTokens.remove(modelId);
    }
  }

  @override
  Future<void> update(String modelId) async {
    final manifest = await _catalog.get(modelId);
    // Nothing to update against: an external model has no remote version.
    if (manifest.delivery == ModelDelivery.external) return;
    final installed =
        await _installer.installedVersion(manifest.type, manifest.id);
    if (installed != null && installed >= manifest.catalogVersion) return;
    _setStatus(modelId, ModelInstallState.updating);
    await install(modelId);
  }

  @override
  Future<void> remove(String modelId) async {
    _cancelTokens[modelId]?.cancel();
    final manifest = await _catalog.get(modelId);
    await _installer.remove(manifest.type, manifest.id);
    final scratch = Directory(_paths.downloadDir(modelId));
    if (scratch.existsSync()) await scratch.delete(recursive: true);
    _setStatus(modelId, ModelInstallState.notInstalled);
  }

  @override
  Future<bool> verify(String modelId) async {
    final manifest = await _catalog.get(modelId);
    final dir = Directory(_paths.modelDir(manifest.type, manifest.id));
    if (!_installer.isInstalled(manifest)) return false;
    // An external model has no trusted sha256 to check against — the app or
    // the user supplied the file. `isInstalled` (marker + non-empty files)
    // is the whole check; see the caveat in docs/model-downloads.md.
    if (manifest.delivery == ModelDelivery.external) return true;
    for (final file in manifest.files) {
      final sub = file.relativePath != null ? '${file.relativePath}/' : '';
      final target = File('${dir.path}/$sub${file.name}');
      if (!target.existsSync()) return false;
      final actual = await DownloadManager.sha256OfFile(target);
      if (actual.toLowerCase() != file.sha256.toLowerCase()) return false;
    }
    return true;
  }

  /// Registers a model whose files the app (or the user) already has on
  /// disk — bring-your-own GGUF, an enterprise MDM push, a sideloaded file
  /// picker result — without going through download or verification.
  ///
  /// [manifest] must declare [ModelDelivery.external]. The file at
  /// [localFilePath] is **linked** into the standard install location
  /// (`models/<type>/<id>/<name>`) so a multi-gigabyte weight file is not
  /// duplicated; Windows, where creating a symlink needs elevation or
  /// developer mode, copies instead. After this call `isInstalled`,
  /// `getStatus` and adapter `load()` treat the model exactly like a
  /// catalog-managed one.
  ///
  /// No integrity check happens: unlike a downloaded model, nothing here is
  /// verified against a sha256. That is the trust model of
  /// [ModelDelivery.external] — the caller vouches for the file.
  ///
  /// [verify] degenerates to an existence check and [update] is a no-op for
  /// models registered this way.
  Future<void> registerExternalModel(
    LocalModelManifest manifest, {
    required String localFilePath,
  }) async {
    if (manifest.delivery != ModelDelivery.external) {
      throw InvalidStateError(
        'registerExternalModel expects ModelDelivery.external, got '
        '${manifest.delivery.name} for model "${manifest.id}".',
      );
    }
    if (manifest.files.length > 1) {
      throw InvalidStateError(
        'registerExternalModel takes a single file, but the manifest for '
        '"${manifest.id}" declares ${manifest.files.length}. Register a '
        'single-file manifest, or install the model through the catalog.',
      );
    }
    final source = File(localFilePath);
    if (!source.existsSync()) {
      throw InvalidStateError(
        'External model file "$localFilePath" does not exist.',
      );
    }

    final fileName = manifest.files.isNotEmpty
        ? manifest.files.first.name
        : localFilePath.split(Platform.pathSeparator).last;
    final target = Directory(_paths.modelDir(manifest.type, manifest.id));
    if (target.existsSync()) await target.delete(recursive: true);
    await target.create(recursive: true);

    final linkPath = '${target.path}${Platform.pathSeparator}$fileName';
    if (Platform.isWindows) {
      await source.copy(linkPath);
    } else {
      await Link(linkPath).create(source.absolute.path);
    }

    // catalogVersion 0 is the "not catalog-tracked" sentinel.
    final marker = File('${target.path}${Platform.pathSeparator}installed.json');
    await marker.writeAsString(jsonEncode(<String, Object?>{
      'modelId': manifest.id,
      'catalogVersion': 0,
      'installedAt': DateTime.now().toIso8601String(),
      'externalSource': source.absolute.path,
    }));

    await _catalog.registerManifest(manifest);
    _setStatus(manifest.id, ModelInstallState.installed,
        installedCatalogVersion: 0);
  }

  /// Installs a TTS voice independently of its base model
  /// (`voices/<voiceId>/` layout).
  Future<void> installVoice(
    String voiceId, {
    required String ttsModelId,
    DownloadPolicy policy = const DownloadPolicy(),
  }) async {
    final manifest = await _catalog.get(ttsModelId);
    final voice = manifest.voices?.firstWhere(
      (v) => v.id == voiceId,
      orElse: () => throw ModelNotFoundError(voiceId),
    );
    if (voice == null) throw ModelNotFoundError(voiceId);

    // Voices reuse the model download pipeline through a synthetic
    // voice-scoped manifest; files land in voices/<voiceId> via a small
    // detour: download to downloads/<voiceId> then move.
    final voiceManifest = LocalModelManifest(
      id: voiceId,
      type: ModelType.tts,
      provider: manifest.provider,
      files: voice.files,
      delivery: ModelDelivery.download,
      catalogVersion: manifest.catalogVersion,
    );
    final dir = await _downloader.download(voiceManifest, policy: policy);
    // Strip .part suffixes, then move into the voices directory.
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.part')) {
        await entity.rename(
            entity.path.substring(0, entity.path.length - '.part'.length));
      }
    }
    final metaFile = File('${dir.path}/meta.json');
    if (metaFile.existsSync()) await metaFile.delete();
    final target = Directory(_paths.voiceDir(voiceId));
    if (target.existsSync()) await target.delete(recursive: true);
    await target.parent.create(recursive: true);
    await dir.rename(target.path);
  }

  /// Installs every model of a catalog [ModelPack].
  Future<void> installPack(
    String packId, {
    DownloadPolicy policy = const DownloadPolicy(),
  }) async {
    final pack = _catalog.packs.firstWhere(
      (p) => p.id == packId,
      orElse: () => throw ModelNotFoundError('pack:$packId'),
    );
    for (final modelId in pack.modelIds) {
      await ensureInstalled(modelId, policy: policy);
    }
  }

  // ---------------------------------------------------------------------------

  void _setStatus(
    String modelId,
    ModelInstallState state, {
    ModelDownloadProgress? progress,
    LocalAIError? error,
    int? installedCatalogVersion,
  }) {
    final previous = _statuses[modelId];
    final status = ModelStatus(
      modelId: modelId,
      state: state,
      progress: progress,
      error: error,
      installedCatalogVersion:
          installedCatalogVersion ?? previous?.installedCatalogVersion,
    );
    _statuses[modelId] = status;
    _statusControllers[modelId]?.add(status);
  }
}
