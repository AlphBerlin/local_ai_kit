import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit/local_ai_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadManager.sha256OfFile', () {
    test('computes sha256 of file stream accurately', () async {
      final tempDir = await Directory.systemTemp.createTemp('sha_test_');
      try {
        final testFile = File('${tempDir.path}/test.txt');
        await testFile.writeAsString('hello world\n');
        final digest = await DownloadManager.sha256OfFile(testFile);
        // sha256("hello world\n") = d9014c4624844aa5bac314773d6b689ad467fa4e1d1a50a1b8a99d5a95f72ff5
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
}
