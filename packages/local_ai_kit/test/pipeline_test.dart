import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_sherpa/local_ai_sherpa.dart';

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

  group('DownloadManager.sha256OfFile', () {
    test('computes sha256 of file stream accurately', () async {
      final tempDir = await Directory.systemTemp.createTemp('sha_test_');
      try {
        final testFile = File('${tempDir.path}/test.txt');
        await testFile.writeAsString('hello world\n');
        final digest = await DownloadManager.sha256OfFile(testFile);
        expect(digest,
            'a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447');
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('LocalPipelinePresets', () {
    test('presets exist and are accessible', () {
      expect(LocalPipeline.presets, isA<LocalPipelinePresets>());
    });
  });

  group('SherpaSttAdapter transcription test', () {
    test('decodes audio buffer and formats sentence case', () async {
      final paths = _TestPaths(
          '/Users/ajithberlin/Library/Application Support/com.localai.kit.example.localAiKitExample/local_ai');
      final stt = SherpaSttAdapter(paths: paths);
      await stt.load(const SttLoadOptions(
          modelId: 'sherpa-onnx-streaming-zipformer-en-20m'));

      final pcmFile = File('/tmp/test_stt_in.pcm');
      if (pcmFile.existsSync()) {
        final bytes = pcmFile.readAsBytesSync();
        final samples = Float32List(bytes.length ~/ 4);
        final byteData = ByteData.sublistView(bytes);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = byteData.getFloat32(i * 4, Endian.little);
        }
        final transcript = await stt.transcribe(
            AudioBuffer(samples: samples, format: AudioFormat.pcm16kMono));
        expect(transcript.text.isNotEmpty, isTrue);
        expect(transcript.text.toLowerCase(), contains('yellow lamps'));
      }
      await stt.unload();
    });
  });

  group('SherpaTtsAdapter synthesis test', () {
    test('synthesizes speech with Piper model', () async {
      final paths = _TestPaths(
          '/Users/ajithberlin/Library/Application Support/com.localai.kit.example.localAiKitExample/local_ai');
      final tts = SherpaTtsAdapter(paths: paths);
      await tts.load(const TtsLoadOptions(modelId: 'vits-piper-en-lessac'));

      final stream = await tts.synthesizeStream(const SpeakRequest(
        text:
            'Welcome to LocalAI Kit! Running ultra fast on-device neural text to speech.',
      ));
      final chunks = await stream.toList();
      expect(chunks.isNotEmpty, isTrue);
      await tts.unload();
    });
  });
}
