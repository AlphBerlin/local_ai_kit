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

/// 2 GB of weights, mobile-only, needing 6 GB of RAM. The URL is
/// unreachable on purpose: any test where the gate lets the download start
/// should fail loudly rather than quietly succeed.
const _bigModel = LocalModelManifest(
  id: 'big-mobile-llm',
  type: ModelType.llm,
  provider: ModelProviders.llamaCpp,
  delivery: ModelDelivery.download,
  platforms: ['android', 'ios'],
  minMemoryMB: 6000,
  files: [
    ModelFile(
      name: 'big.gguf',
      url: 'http://127.0.0.1:1/big.gguf',
      sha256: kPlaceholderSha256,
      sizeBytes: 2048 * 1024 * 1024,
    ),
  ],
);

DeviceCapabilities caps({
  int totalMemoryMB = 8192,
  int availableMemoryMB = 7000,
  int freeDiskMB = 65536,
  String platform = 'android',
}) =>
    DeviceCapabilities(
      totalMemoryMB: totalMemoryMB,
      availableMemoryMB: availableMemoryMB,
      freeDiskMB: freeDiskMB,
      platform: platform,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _TestPaths paths;
  late ModelCatalogService catalog;

  Future<ModelManagerImpl> manager({
    required DeviceCapabilities device,
    CompatibilityEnforcement enforcement = CompatibilityEnforcement.enforce,
  }) async {
    await catalog.registerManifest(_bigModel);
    return ModelManagerImpl(
      paths: paths,
      catalog: catalog,
      networkPolicy: _TestNetworkPolicy(),
      deviceProbe: () async => device,
      compatibilityEnforcement: enforcement,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('compat_gate_test_');
    paths = _TestPaths(tempDir.path);
    await paths.ensureInitialized();
    catalog = ModelCatalogService(paths: paths);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('checkCompatibility reports without side effects', () {
    test('a capable device passes', () async {
      final m = await manager(device: caps());
      final report = await m.checkCompatibility('big-mobile-llm');

      expect(report.isCompatible, isTrue);
      expect(
          Directory(paths.downloadDir('big-mobile-llm')).existsSync(), isFalse);
    });

    test('too little disk is reported before any bytes move', () async {
      final m = await manager(device: caps(freeDiskMB: 1000));
      final report = await m.checkCompatibility('big-mobile-llm');

      expect(report.isCompatible, isFalse);
      expect(report.blockers.map((i) => i.check),
          contains(CompatibilityCheck.disk));
      expect(report.reasons.single, contains('2458MB free disk'));
    });

    test('too little RAM is reported', () async {
      final m = await manager(device: caps(totalMemoryMB: 4096));
      final report = await m.checkCompatibility('big-mobile-llm');

      expect(report.isCompatible, isFalse);
      expect(report.blockers.map((i) => i.check),
          contains(CompatibilityCheck.totalMemory));
    });

    test('an unsupported platform is reported', () async {
      final m = await manager(device: caps(platform: 'linux'));
      final report = await m.checkCompatibility('big-mobile-llm');

      expect(report.isCompatible, isFalse);
      expect(report.reasons.single, contains('does not support linux'));
    });

    test('a compatible-but-tight device carries warnings', () async {
      final m = await manager(device: caps(availableMemoryMB: 6100));
      final report = await m.checkCompatibility('big-mobile-llm');

      expect(report.isCompatible, isTrue);
      expect(report.hasWarnings, isTrue);
      expect(report.summary, startsWith('compatible with warnings:'));
    });

    test('an unknown model id still throws ModelNotFoundError', () async {
      final m = await manager(device: caps());
      await expectLater(
        m.checkCompatibility('no-such-model'),
        throwsA(isA<ModelNotFoundError>()),
      );
    });
  });

  group('install gate', () {
    test('an incompatible device fails before the download starts', () async {
      final m = await manager(device: caps(freeDiskMB: 1000));

      await expectLater(
        m.install('big-mobile-llm'),
        throwsA(isA<IncompatibleDeviceError>()),
      );
      // Nothing was written: the gate runs before the downloader is asked
      // for a scratch directory.
      expect(
          Directory(paths.downloadDir('big-mobile-llm')).existsSync(), isFalse);
    });

    test('the failure reaches watchStatus with the report attached', () async {
      final m = await manager(device: caps(totalMemoryMB: 2048));

      final seen = <ModelStatus>[];
      final sub = m.watchStatus('big-mobile-llm').listen(seen.add);
      addTearDown(sub.cancel);

      await expectLater(
        m.ensureInstalled('big-mobile-llm'),
        throwsA(isA<IncompatibleDeviceError>()),
      );
      await pumpEventQueue();

      final failed = seen.lastWhere((s) => s.state == ModelInstallState.failed);
      expect(failed.error, isA<IncompatibleDeviceError>());

      // `getStatus` deliberately re-derives a failed model from disk rather
      // than serving the cached failure, so it reports the on-disk truth.
      final status = await m.getStatus('big-mobile-llm');
      expect(status.state, ModelInstallState.notInstalled);
    });

    test('the thrown error carries the full report', () async {
      final m = await manager(device: caps(platform: 'windows'));

      await expectLater(
        m.install('big-mobile-llm'),
        throwsA(isA<IncompatibleDeviceError>().having(
          (e) => e.report.blockers.single.check,
          'blocking check',
          CompatibilityCheck.platform,
        )),
      );
    });

    test('warn enforcement lets the download proceed to a network error',
        () async {
      final m = await manager(
        device: caps(freeDiskMB: 1000),
        enforcement: CompatibilityEnforcement.warn,
      );

      // The gate no longer blocks, so the call gets as far as the
      // downloader — which fails on disk or network, not on compatibility.
      await expectLater(
        m.install('big-mobile-llm'),
        throwsA(isA<LocalAIError>().having(
            (e) => e,
            'not a compatibility failure',
            isNot(isA<IncompatibleDeviceError>()))),
      );
    });

    test('no probe means no gate, exactly as before this feature', () async {
      await catalog.registerManifest(_bigModel);
      final m = ModelManagerImpl(
        paths: paths,
        catalog: catalog,
        networkPolicy: _TestNetworkPolicy(),
      );

      final report = await m.checkCompatibility('big-mobile-llm');
      expect(report.isCompatible, isTrue);
    });

    test('a failing probe does not block a download it could not judge',
        () async {
      await catalog.registerManifest(_bigModel);
      final m = ModelManagerImpl(
        paths: paths,
        catalog: catalog,
        networkPolicy: _TestNetworkPolicy(),
        deviceProbe: () async => throw StateError('probe unavailable'),
      );

      final report = await m.checkCompatibility('big-mobile-llm');
      expect(report.isCompatible, isTrue);
    });
  });
}
