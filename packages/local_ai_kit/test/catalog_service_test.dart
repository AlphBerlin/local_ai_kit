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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _TestPaths paths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('catalog_test_');
    paths = _TestPaths(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ModelCatalogService', () {
    test('resolves built-in models without on-disk cache', () async {
      final service = ModelCatalogService(paths: paths);
      await service.refresh();

      final manifest = await service.get('qwen-3.5-2b-instruct');
      expect(manifest.id, 'qwen-3.5-2b-instruct');
      expect(manifest.displayName, contains('Qwen 3.5 2B'));

      final allModels = await service.list();
      expect(allModels.map((m) => m.id), contains('qwen-3.5-2b-instruct'));
      expect(allModels.map((m) => m.id), contains('smollm2-360m-instruct'));
      expect(allModels.map((m) => m.id), contains('deepseek-r1-1.5b-int4'));
    });

    test(
        'preserves built-in Models.all even when stale catalog.merged.json is on disk',
        () async {
      // Simulate an old version of the app having saved catalog.merged.json with only 1 model
      final manifestsDir = Directory(paths.manifestsDir);
      await manifestsDir.create(recursive: true);
      final staleCatalogFile =
          File('${paths.manifestsDir}/catalog.merged.json');
      await staleCatalogFile.writeAsString(jsonEncode({
        'models': [
          {
            'id': 'legacy-model-1',
            'type': 'llm',
            'provider': 'google-gemma',
            'displayName': 'Legacy Model',
            'description': 'Old cached model',
            'delivery': 'download',
            'catalogVersion': 1,
            'files': [
              {
                'name': 'legacy.task',
                'url': 'https://example.com/legacy.task',
                'sha256':
                    '0000000000000000000000000000000000000000000000000000000000000000',
                'sizeBytes': 1000,
              }
            ]
          }
        ]
      }));

      final service = ModelCatalogService(paths: paths);
      await service.refresh();

      // Qwen 3.5 2B must NOT be dropped
      final qwenManifest = await service.get('qwen-3.5-2b-instruct');
      expect(qwenManifest.id, 'qwen-3.5-2b-instruct');

      // Legacy model from disk must also be retained
      final legacyManifest = await service.get('legacy-model-1');
      expect(legacyManifest.id, 'legacy-model-1');

      // All compile-time built-ins should still be present
      for (final builtin in Models.all) {
        final found = await service.get(builtin.id);
        expect(found.id, builtin.id);
      }
    });

    test('throws ModelNotFoundError for unknown model ids', () async {
      final service = ModelCatalogService(paths: paths);
      await service.refresh();

      expect(
        () => service.get('non-existent-model-id'),
        throwsA(isA<ModelNotFoundError>()),
      );
    });
  });

  group('ModelInstaller payload validation and crash recovery', () {
    test(
        'isInstalled returns false when payload weights are missing despite installed.json',
        () async {
      final installer = ModelInstaller(paths: paths);
      final modelDir =
          Directory(paths.modelDir(ModelType.llm, 'qwen-3.5-2b-instruct'));
      await modelDir.create(recursive: true);
      final marker = File('${modelDir.path}/installed.json');
      await marker.writeAsString(
          jsonEncode({'modelId': 'qwen-3.5-2b-instruct', 'catalogVersion': 1}));

      // No actual weight files in modelDir
      expect(installer.isInstalled(Models.qwen35_2b), isFalse);

      // Now create the weight file
      final weightFile = File('${modelDir.path}/Qwen3.5-2B_int8.litertlm');
      await weightFile.writeAsString('test weight data');
      expect(installer.isInstalled(Models.qwen35_2b), isTrue);
    });

    test(
        'recoverFromCrash deletes directories with only installed.json and no payloads',
        () async {
      final installer = ModelInstaller(paths: paths);
      final modelDir =
          Directory(paths.modelDir(ModelType.llm, 'corrupt-model'));
      await modelDir.create(recursive: true);
      final marker = File('${modelDir.path}/installed.json');
      await marker.writeAsString(
          jsonEncode({'modelId': 'corrupt-model', 'catalogVersion': 1}));

      expect(await modelDir.exists(), isTrue);
      await installer.recoverFromCrash();
      expect(await modelDir.exists(), isFalse);
    });
  });
}
