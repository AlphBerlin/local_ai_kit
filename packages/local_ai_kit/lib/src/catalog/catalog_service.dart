/// `LocalModelCatalog` implementation: built-in fallback + remote merge +
/// persistence (architecture §5.5).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_ai_core/local_ai_core.dart';

import 'catalog_merger.dart';
import 'remote_catalog_loader.dart';

/// Serves the merged model catalog.
///
/// Resolution order for [refresh]: fetch remote → on failure use cached
/// remote → on absence use built-in [Models.all]. The merged result is
/// persisted to `manifests/catalog.merged.json`.
class ModelCatalogService implements LocalModelCatalog {
  ModelCatalogService({
    required LocalStoragePaths paths,
    Uri? remoteCatalogUrl,
    RemoteCatalogLoader? loader,
  })  : _paths = paths,
        _remoteCatalogUrl = remoteCatalogUrl,
        _loader = loader ?? RemoteCatalogLoader(paths: paths);

  final LocalStoragePaths _paths;
  final Uri? _remoteCatalogUrl;
  final RemoteCatalogLoader _loader;

  Map<String, LocalModelManifest> _merged = {
    for (final manifest in Models.all) manifest.id: manifest,
  };
  Set<String> _updatable = {};

  static final List<ModelPack> _packs = [
    const ModelPack(
      id: 'voice-assistant-pack',
      name: 'Voice Assistant Pack',
      description: 'Everything needed for a full voice assistant: '
          'Silero VAD + SenseVoice STT + Gemma 3n + Supertonic TTS.',
      modelIds: [
        'silero-vad',
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
        'gemma-3n-e2b-it-int4',
        'supertonic-tts',
      ],
    ),
    const ModelPack(
      id: 'transcription-pack',
      name: 'Transcription Pack',
      description: 'Silero VAD + SenseVoice STT for offline transcription.',
      modelIds: [
        'silero-vad',
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
      ],
    ),
  ];

  /// Ids whose remote manifest is newer and whose files changed (rule 4).
  Set<String> get updatable => Set.unmodifiable(_updatable);

  @override
  List<ModelPack> get packs => List.unmodifiable(_packs);

  @override
  Future<List<LocalModelManifest>> list(
      {ModelType? type, String? language}) async {
    var manifests = _merged.values.toList();
    if (type != null) {
      manifests = manifests.where((m) => m.type == type).toList();
    }
    if (language != null) {
      manifests = manifests
          .where((m) =>
              m.languages.contains(language) ||
              m.languages.contains('multilingual'))
          .toList();
    }
    return manifests;
  }

  @override
  Future<LocalModelManifest> get(String modelId) async {
    final manifest = _merged[modelId];
    if (manifest == null) throw ModelNotFoundError(modelId);
    return manifest;
  }

  @override
  Future<void> refresh() async {
    await _restoreMergedFromDisk();

    RemoteCatalog? remote;
    final url = _remoteCatalogUrl;
    if (url != null) {
      remote = await _loader.fetch(url);
    }
    remote ??= await _loader.loadCached();

    if (remote != null) {
      final result = CatalogMerger.merge(
        Models.all,
        remote.models,
        installedVersions: await _installedVersions(),
      );
      _merged = result.merged;
      _updatable = result.updatable;
      await _persistMerged();
    }
  }

  @override
  Future<void> installPack(String packId) {
    throw UnsupportedError(
        'installPack needs the model manager; use ModelHub.installPack.');
  }

  // ---------------------------------------------------------------------------

  File get _mergedFile => File('${_paths.manifestsDir}/catalog.merged.json');

  Future<Map<String, int>> _installedVersions() async {
    final result = <String, int>{};
    final modelsRoot = Directory(_paths.modelsDir);
    if (!modelsRoot.existsSync()) return result;
    await for (final typeDir in modelsRoot.list()) {
      if (typeDir is! Directory) continue;
      await for (final modelDir in typeDir.list()) {
        if (modelDir is! Directory) continue;
        final marker = File('${modelDir.path}/installed.json');
        if (!marker.existsSync()) continue;
        try {
          final json = jsonDecode(await marker.readAsString()) as Map;
          final id = modelDir.path.split(Platform.pathSeparator).last;
          final version = json['catalogVersion'] as int?;
          if (version != null) result[id] = version;
        } on Object {
          // Corrupt marker: ignore, recovery handled by ModelInstaller.
        }
      }
    }
    return result;
  }

  Future<void> _persistMerged() async {
    await _mergedFile.parent.create(recursive: true);
    final tmp = File('${_mergedFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, Object?>{
        'models': _merged.values.map((m) => m.toJson()).toList(),
      }),
      flush: true,
    );
    await tmp.rename(_mergedFile.path);
  }

  Future<void> _restoreMergedFromDisk() async {
    try {
      if (!_mergedFile.existsSync()) return;
      final json = (jsonDecode(await _mergedFile.readAsString()) as Map)
          .cast<String, Object?>();
      final models = (json['models'] as List)
          .map((e) =>
              LocalModelManifest.fromJson((e as Map).cast<String, Object?>()))
          .toList();
      _merged = {for (final manifest in models) manifest.id: manifest};
    } on Object {
      // Corrupt merged file: keep built-in fallback.
    }
  }
}