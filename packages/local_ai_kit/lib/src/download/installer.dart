/// Atomic install + crash recovery for downloaded models (§5.1.5).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

/// Moves a fully-downloaded `downloads/<id>/` directory into its final
/// `models/<type>/<id>/` location via same-partition atomic rename, then
/// stamps `installed.json`.
class ModelInstaller {
  ModelInstaller({required LocalStoragePaths paths}) : _paths = paths;

  final LocalStoragePaths _paths;

  static const _installedMarker = 'installed.json';

  /// Atomically installs [downloadDir] as [manifest]'s model directory.
  ///
  /// `*.part` suffixes are stripped during a staging copy inside the
  /// download dir, then the whole directory is renamed — the rename is the
  /// only observable state change, so readers never see a partial install.
  Future<Directory> install(
      LocalModelManifest manifest, Directory downloadDir) async {
    // Strip .part suffixes in place (same partition → rename is cheap).
    await for (final entity
        in downloadDir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.part')) {
        await entity.rename(
            entity.path.substring(0, entity.path.length - '.part'.length));
      }
    }
    // meta.json is download bookkeeping; it must not ship with the model.
    final metaFile = File('${downloadDir.path}/meta.json');
    if (metaFile.existsSync()) await metaFile.delete();

    final target = Directory(_paths.modelDir(manifest.type, manifest.id));
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await target.parent.create(recursive: true);
    await downloadDir.rename(target.path);

    final marker = File('${target.path}/$_installedMarker');
    await marker.writeAsString(jsonEncode(<String, Object?>{
      'modelId': manifest.id,
      'catalogVersion': manifest.catalogVersion,
      'installedAt': DateTime.now().toIso8601String(),
    }));

    // Auto-extract archives (.tar.bz2, .tar.gz, .tar) if present
    for (final entity in target.listSync(recursive: false)) {
      if (entity is File) {
        if (entity.path.endsWith('.tar.bz2') ||
            entity.path.endsWith('.tar.gz') ||
            entity.path.endsWith('.tar')) {
          try {
            await Process.run('tar', ['-xf', entity.path, '-C', target.path]);
          } catch (_) {}
        }
      }
    }

    return target;
  }

  /// Whether [manifest] is installed with all its required files present on disk.
  bool isInstalled(LocalModelManifest manifest) {
    final dir = _paths.modelDir(manifest.type, manifest.id);
    final marker = File('$dir/$_installedMarker');
    if (!marker.existsSync()) return false;
    for (final file in manifest.files) {
      final sub = file.relativePath != null ? '${file.relativePath}/' : '';
      final target = File('$dir/$sub${file.name}');
      if (!target.existsSync() || target.lengthSync() == 0) return false;
    }
    return true;
  }

  /// Fallback check by type and modelId (checks marker and that payload files exist).
  bool isInstalledType(ModelType type, String modelId) {
    final dir = Directory(_paths.modelDir(type, modelId));
    if (!dir.existsSync()) return false;
    final marker = File('${dir.path}/$_installedMarker');
    if (!marker.existsSync()) return false;
    final payloadFiles = dir.listSync().whereType<File>().where((f) =>
        !f.path.endsWith(_installedMarker) && !f.path.endsWith('.DS_Store'));
    return payloadFiles.isNotEmpty;
  }

  /// The catalog version of the installed copy, or `null`.
  Future<int?> installedVersion(ModelType type, String modelId) async {
    final marker = File('${_paths.modelDir(type, modelId)}/$_installedMarker');
    if (!marker.existsSync()) return null;
    try {
      final json = jsonDecode(await marker.readAsString());
      return (json as Map)['catalogVersion'] as int?;
    } on Object {
      return null;
    }
  }

  /// Deletes the installed model directory. Returns false when absent.
  Future<bool> remove(ModelType type, String modelId) async {
    final dir = Directory(_paths.modelDir(type, modelId));
    if (!dir.existsSync()) return false;
    await dir.delete(recursive: true);
    return true;
  }

  /// Crash recovery at startup (architecture §5.1.5):
  ///  * deletes `models/**` directories missing `installed.json`
  ///    (half-installed leftovers)
  ///  * deletes `models/**` directories that only contain `installed.json`
  ///    with no actual weight/payload files
  ///  * leaves `downloads/*` in place so downloads resume
  Future<void> recoverFromCrash() async {
    final modelsRoot = Directory(_paths.modelsDir);
    if (!modelsRoot.existsSync()) return;
    await for (final typeDir in modelsRoot.list()) {
      if (typeDir is! Directory) continue;
      await for (final modelDir in typeDir.list()) {
        if (modelDir is! Directory) continue;
        final marker = File('${modelDir.path}/$_installedMarker');
        if (!marker.existsSync()) {
          await modelDir.delete(recursive: true);
          continue;
        }
        final payloadFiles = modelDir.listSync().whereType<File>().where((f) =>
            !f.path.endsWith(_installedMarker) &&
            !f.path.endsWith('.DS_Store'));
        if (payloadFiles.isEmpty) {
          await modelDir.delete(recursive: true);
        }
      }
    }
  }
}
