/// Remote catalog fetching with on-disk caching (architecture §5.5).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

/// Fetches `{catalogVersion, updatedAt, models: [...]}` JSON over HTTPS and
/// caches it to `manifests/catalog.remote.json`.
class RemoteCatalogLoader {
  RemoteCatalogLoader({
    required LocalStoragePaths paths,
    HttpClient? httpClient,
  })  : _paths = paths,
        _client = httpClient ?? HttpClient();

  final LocalStoragePaths _paths;
  final HttpClient _client;

  static const _cacheFileName = 'catalog.remote.json';
  static const _timeout = Duration(seconds: 15);

  /// The merged catalog output file (`catalog.merged.json`) is written by
  /// `ModelCatalogService` after merging.
  File get _cacheFile => File('${_paths.manifestsDir}/$_cacheFileName');

  /// Fetches the remote catalog. Returns `null` on any network/parse
  /// failure — callers fall back to the cache, then to the built-in
  /// catalog.
  Future<RemoteCatalog?> fetch(Uri url) async {
    try {
      final request = await _client.getUrl(url).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response.transform(utf8.decoder).join();
      final catalog = RemoteCatalog.parse(body);
      await _cache(catalog.rawJson);
      return catalog;
    } on Object {
      return null;
    }
  }

  /// The last successfully fetched catalog from disk, or `null`.
  Future<RemoteCatalog?> loadCached() async {
    try {
      if (!_cacheFile.existsSync()) return null;
      return RemoteCatalog.parse(await _cacheFile.readAsString());
    } on Object {
      return null;
    }
  }

  Future<void> _cache(String rawJson) async {
    await _cacheFile.parent.create(recursive: true);
    final tmp = File('${_cacheFile.path}.tmp');
    await tmp.writeAsString(rawJson, flush: true);
    await tmp.rename(_cacheFile.path);
  }
}

/// A parsed remote catalog document.
class RemoteCatalog {
  RemoteCatalog({
    required this.catalogVersion,
    required this.models,
    required this.rawJson,
    this.updatedAt,
  });

  final int catalogVersion;
  final List<LocalModelManifest> models;
  final String rawJson;
  final DateTime? updatedAt;

  static RemoteCatalog parse(String body) {
    final json = (jsonDecode(body) as Map).cast<String, Object?>();
    final models = (json['models'] as List)
        .map((e) => LocalModelManifest.fromJson((e as Map).cast<String, Object?>()))
        .toList();
    return RemoteCatalog(
      catalogVersion: json['catalogVersion'] as int? ?? 1,
      models: models,
      rawJson: body,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
    );
  }
}
