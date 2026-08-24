/// Built-in ↔ remote catalog merge (architecture §5.5).
///
/// Rules (by model id):
///  1. remote `catalogVersion` > local → remote entry wins;
///  2. remote-only ids are appended;
///  3. remote never removes entries (installed models keep their manifest);
///  4. when the remote changes `files[].sha256` of an installed model with
///     a higher version, the model is flagged [CatalogMerger.updatable]
///     (status moves to `updating`; it is NOT auto-reinstalled).
library;

import 'package:local_ai_core/local_ai_core.dart';

class CatalogMergeResult {
  const CatalogMergeResult({required this.merged, required this.updatable});

  /// Merged manifests keyed by id.
  final Map<String, LocalModelManifest> merged;

  /// Ids of installed models whose remote manifest has a newer
  /// `catalogVersion` AND different file hashes.
  final Set<String> updatable;
}

class CatalogMerger {
  /// Merges [builtin] with [remote] entries.
  ///
  /// [installedVersions] maps modelId → installed catalogVersion, used for
  /// rule 4 (updatable detection).
  static CatalogMergeResult merge(
    List<LocalModelManifest> builtin,
    List<LocalModelManifest> remote, {
    Map<String, int> installedVersions = const {},
  }) {
    final merged = <String, LocalModelManifest>{
      for (final manifest in builtin) manifest.id: manifest,
    };
    final updatable = <String>{};

    for (final remoteManifest in remote) {
      final local = merged[remoteManifest.id];
      if (local == null ||
          remoteManifest.catalogVersion > local.catalogVersion) {
        merged[remoteManifest.id] = remoteManifest;
        final installedVersion = installedVersions[remoteManifest.id];
        if (local != null &&
            installedVersion != null &&
            _filesChanged(local.files, remoteManifest.files)) {
          updatable.add(remoteManifest.id);
        }
      }
    }
    return CatalogMergeResult(merged: merged, updatable: updatable);
  }

  static bool _filesChanged(List<ModelFile> a, List<ModelFile> b) {
    if (a.length != b.length) return true;
    final hashesA = a.map((f) => '${f.name}:${f.sha256}').toSet();
    final hashesB = b.map((f) => '${f.name}:${f.sha256}').toSet();
    return !(hashesA.containsAll(hashesB) && hashesB.containsAll(hashesA));
  }
}
