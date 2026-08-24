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
    return target;
  }

  /// Whether [type]/[modelId] is installed (marker file present).
  bool isInstalled(ModelType type, String modelId) =>
      File('${_paths.modelDir(type, modelId)}/$_installedMarker').existsSync();

  /// The catalog version of the installed copy, or `null`.
  Future<int?> installedVersion(ModelType type, String modelId) async {
    final marker =
        File('${_paths.modelDir(type, modelId)}/$_installedMarker');
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
        }
      }
    }
  }
}
