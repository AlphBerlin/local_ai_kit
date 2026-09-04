import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit/local_ai_kit.dart';

class _TestPaths implements LocalStoragePaths {
  _TestPaths(this.rootDir);
  @override
  final String rootDir;
  @override
  String get modelsDir => '$rootDir/models';
  @override
  String modelDir(ModelType type, String modelId) =>
      '$modelsDir/${type.name}/$modelId';
  @override
  String get downloadsDir => '$rootDir/downloads';
  @override
  String downloadDir(String modelId) => '$downloadsDir/$modelId';
  @override
  String get voicesDir => '$rootDir/voices';
  @override
  String voiceDir(String voiceId) => '$voicesDir/$voiceId';
  @override
  String get manifestsDir => '$rootDir/manifests';
  @override
  String get cacheDir => '$rootDir/cache';
  @override
  Future<void> ensureInitialized() async {
    await Directory(manifestsDir).create(recursive: true);
    await Directory(modelsDir).create(recursive: true);
    await Directory(downloadsDir).create(recursive: true);
    await Directory(cacheDir).create(recursive: true);
    await Directory(voicesDir).create(recursive: true);
  }
}

class _TestNetworkPolicy implements NetworkPolicy {
  @override
  Future<bool> canDownload({bool wifiOnly = true}) async => true;
  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
  @override
  Stream<NetworkStatus> get onStatusChanged => const Stream.empty();
}

/// Minimal in-memory [LocalEmbedding]; `local_ai_core` ships no fake for
/// this capability yet.
class _FakeEmbedding implements LocalEmbedding {
  int loadCount = 0;
  int unloadCount = 0;
  int? requestedDimensions;

  @override
  Future<void> load(EmbeddingLoadOptions options) async {
    loadCount++;
    requestedDimensions = options.dimensions;
  }

  @override
  Future<void> unload() async => unloadCount++;

  @override
  Future<List<double>> embed(String text) async =>
      <double>[text.length.toDouble(), 0, 0];

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      <List<double>>[for (final text in texts) await embed(text)];
}

class _FakeEmbeddingPlugin implements AdapterPlugin {
  _FakeEmbeddingPlugin(this.embedding);
  final _FakeEmbedding embedding;

  @override
  void register(AdapterRegistry registry) {
    registry.registerEmbedding(
      ModelProviders.llamaCpp,
      (context) => embedding,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _TestPaths paths;
  late _FakeEmbedding embedding;

  Future<LocalAI> initialize({EmbeddingConfig? config}) async {
    // Pre-install the catalog's GGUF embedding model so the facade's
    // ensure-installed step is satisfied without a download.
    final modelDir = Directory(
        paths.modelDir(ModelType.embedding, 'nomic-embed-text-v1.5-gguf'));
    await modelDir.create(recursive: true);
    await File('${modelDir.path}/installed.json')
        .writeAsString('{"modelId":"nomic-embed-text-v1.5-gguf",'
            '"catalogVersion":1}');
    await File('${modelDir.path}/nomic-embed-text-v1.5.Q4_K_M.gguf')
        .writeAsString('dummy_bytes');

    return LocalAI.initialize(
      LocalAIConfig(embedding: config),
      plugins: [_FakeEmbeddingPlugin(embedding)],
      paths: paths,
      networkPolicy: _TestNetworkPolicy(),
      enableAudio: false,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('embedding_facade_test_');
    paths = _TestPaths(tempDir.path);
    await paths.ensureInitialized();
    embedding = _FakeEmbedding();
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('ai.embed loads the model lazily and delegates to the adapter',
      () async {
    final ai = await initialize(
      config: const EmbeddingConfig(
        modelId: 'nomic-embed-text-v1.5-gguf',
        dimensions: 256,
      ),
    );

    expect(ai.embeddings.isLoaded, isFalse);
    expect(await ai.embed('abcd'), [4.0, 0, 0]);
    expect(ai.embeddings.isLoaded, isTrue);
    expect(embedding.loadCount, 1);
    expect(embedding.requestedDimensions, 256);

    // A second call reuses the loaded model.
    expect(await ai.embedBatch(['a', 'bc']), [
      [1.0, 0, 0],
      [2.0, 0, 0],
    ]);
    expect(embedding.loadCount, 1);

    await ai.embeddings.unload();
    expect(embedding.unloadCount, 1);
    expect(ai.embeddings.isLoaded, isFalse);

    await ai.dispose();
  });

  test('embedding without configuration fails with a clear message', () async {
    final ai = await initialize();
    await expectLater(
      ai.embed('hello'),
      throwsA(isA<InvalidStateError>()),
    );
    await ai.dispose();
  });
}
