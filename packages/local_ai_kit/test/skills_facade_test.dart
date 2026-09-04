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

class _FakeLlmPlugin implements AdapterPlugin {
  _FakeLlmPlugin(this.fakeLlm);
  final FakeLlm fakeLlm;

  @override
  void register(AdapterRegistry registry) {
    registry.registerLlm(
      ModelProviders.googleGemma,
      (context) => fakeLlm,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LocalAI skills initialization and generation', () async {
    final tempDir = await Directory.systemTemp.createTemp('local_ai_test_');
    final paths = _TestPaths(tempDir.path);
    await paths.ensureInitialized();

    // Pre-install smollm2 in test environment with installed.json marker
    final modelDir =
        Directory(paths.modelDir(ModelType.llm, 'smollm2-360m-instruct'));
    await modelDir.create(recursive: true);
    await File('${modelDir.path}/installed.json').writeAsString(
      jsonEncode({'modelId': 'smollm2-360m-instruct', 'catalogVersion': 1}),
    );
    await File('${modelDir.path}/SmolLM2_360M_instruct.litertlm')
        .writeAsString('dummy_bytes');

    var turns = 0;
    final fakeLlm = FakeLlm(
      handler: (req) async* {
        turns++;
        if (turns == 1) {
          yield const LlmChunk(
            textDelta:
                '{"tool": "calculate", "arguments": {"expression": "50 * 20"}}',
          );
        } else {
          yield const LlmChunk(
            textDelta: 'The answer is 1000.',
          );
        }
        yield const LlmChunk(isFinal: true, finishReason: LlmFinishReason.stop);
      },
    );

    final ai = await LocalAI.initialize(
      const LocalAIConfig(
        remoteCatalogUrl: null,
        llm: LlmConfig(modelId: 'smollm2-360m-instruct'),
      ),
      plugins: [_FakeLlmPlugin(fakeLlm)],
      paths: paths,
      networkPolicy: _TestNetworkPolicy(),
      enableAudio: false,
      // Pin the device the compatibility checker sees. Without this the
      // test asserts against whatever host runs it — and the catalog
      // manifest for this model does not list linux, so CI would fail on
      // a real (correct) `IncompatibleDeviceError`.
      deviceProbe: () async => const DeviceCapabilities(
        totalMemoryMB: 8192,
        availableMemoryMB: 6144,
        freeDiskMB: 32768,
        platform: 'android',
      ),
    );

    expect(ai.skills, isNotNull);
    expect(ai.skills.isEnabled('calculator'), isTrue);
    expect(ai.skills.isEnabled('device_time'), isTrue);

    final result = await ai.generateWithSkills('Compute 50 * 20');
    expect(result.usedTools, isTrue);
    expect(result.toolCalls.first.name, 'calculate');
    expect(result.text, 'The answer is 1000.');

    await ai.dispose();
    await tempDir.delete(recursive: true);
  });
}
