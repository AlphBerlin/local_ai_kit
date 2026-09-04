import 'dart:convert';
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
  Future<void> ensureInitialized() async {}
}

class _TestNetworkPolicy implements NetworkPolicy {
  @override
  Future<bool> canDownload({bool wifiOnly = true}) async => true;
  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
  @override
  Stream<NetworkStatus> get onStatusChanged => const Stream.empty();
}

const _manifest = LocalModelManifest(
  id: 'byo-gguf',
  type: ModelType.llm,
  provider: ModelProviders.llamaCpp,
  delivery: ModelDelivery.external,
  files: [
    ModelFile(name: 'byo.gguf', url: '', sha256: '', sizeBytes: 0),
  ],
);

void main() {
  late Directory tempDir;
  late _TestPaths paths;
  late ModelCatalogService catalog;
  late ModelManagerImpl manager;
  late File source;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('external_model_test_');
    paths = _TestPaths(tempDir.path);
    catalog = ModelCatalogService(paths: paths);
    manager = ModelManagerImpl(
      paths: paths,
      catalog: catalog,
      networkPolicy: _TestNetworkPolicy(),
    );
    source = File('${tempDir.path}/downloads-elsewhere/my-model.gguf');
    await source.parent.create(recursive: true);
    await source.writeAsString('GGUF weights, pretend.');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('an external model becomes installed and resolvable from the catalog',
      () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);

    expect(await manager.isInstalled('byo-gguf'), isTrue);
    final status = await manager.getStatus('byo-gguf');
    expect(status.state, ModelInstallState.installed);
    expect((await catalog.get('byo-gguf')).id, 'byo-gguf');
  });

  test('the weight file is linked, not copied, on POSIX', () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);

    final installed =
        '${paths.modelDir(ModelType.llm, 'byo-gguf')}/byo.gguf';
    expect(FileSystemEntity.isLinkSync(installed), isTrue);
    expect(Link(installed).targetSync(), source.absolute.path);
    expect(File(installed).readAsStringSync(), 'GGUF weights, pretend.');
  }, skip: Platform.isWindows ? 'Windows copies instead of linking' : null);

  test('the marker records the not-catalog-tracked sentinel', () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);

    final marker = File(
        '${paths.modelDir(ModelType.llm, 'byo-gguf')}/installed.json');
    final json = jsonDecode(marker.readAsStringSync()) as Map<String, Object?>;
    expect(json['catalogVersion'], 0);
    expect(json['externalSource'], source.absolute.path);
  });

  test('the sentinel does not make the model look updatable', () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);
    // A fresh manager re-reads the marker from disk instead of its cache.
    final reopened = ModelManagerImpl(
      paths: paths,
      catalog: catalog,
      networkPolicy: _TestNetworkPolicy(),
    );

    final status = await reopened.getStatus('byo-gguf');
    expect(status.state, ModelInstallState.installed);
    expect(status.installedCatalogVersion, 0);
  });

  test('verify is an existence check and update is a no-op', () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);

    // No sha256 to check against: verify passes on presence alone.
    expect(await manager.verify('byo-gguf'), isTrue);
    await manager.update('byo-gguf');
    expect(await manager.isInstalled('byo-gguf'), isTrue);

    await source.delete();
    expect(await manager.verify('byo-gguf'), isFalse);
  });

  test('re-registering replaces the previous link', () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);
    final replacement = File('${tempDir.path}/other/my-model.gguf');
    await replacement.parent.create(recursive: true);
    await replacement.writeAsString('Different weights.');

    await manager.registerExternalModel(_manifest,
        localFilePath: replacement.path);

    final installed =
        '${paths.modelDir(ModelType.llm, 'byo-gguf')}/byo.gguf';
    expect(File(installed).readAsStringSync(), 'Different weights.');
  });

  test('a non-external manifest is rejected', () async {
    const downloadManifest = LocalModelManifest(
      id: 'byo-gguf',
      type: ModelType.llm,
      provider: ModelProviders.llamaCpp,
      delivery: ModelDelivery.download,
      files: [ModelFile(name: 'byo.gguf', url: '', sha256: '', sizeBytes: 0)],
    );
    await expectLater(
      manager.registerExternalModel(downloadManifest,
          localFilePath: source.path),
      throwsA(isA<InvalidStateError>()),
    );
  });

  test('a multi-file manifest is rejected', () async {
    const multiFile = LocalModelManifest(
      id: 'byo-gguf',
      type: ModelType.llm,
      provider: ModelProviders.llamaCpp,
      delivery: ModelDelivery.external,
      files: [
        ModelFile(name: 'a.gguf', url: '', sha256: '', sizeBytes: 0),
        ModelFile(name: 'b.gguf', url: '', sha256: '', sizeBytes: 0),
      ],
    );
    await expectLater(
      manager.registerExternalModel(multiFile, localFilePath: source.path),
      throwsA(isA<InvalidStateError>()),
    );
  });

  test('a missing source file is rejected', () async {
    await expectLater(
      manager.registerExternalModel(_manifest,
          localFilePath: '${tempDir.path}/nope.gguf'),
      throwsA(isA<InvalidStateError>()),
    );
  });

  test('remove deletes the install without touching the source file',
      () async {
    await manager.registerExternalModel(_manifest, localFilePath: source.path);
    await manager.remove('byo-gguf');

    expect(await manager.isInstalled('byo-gguf'), isFalse);
    expect(source.existsSync(), isTrue);
  });
}
