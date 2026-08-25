import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

void main() {
  HttpOverrides.global = _TestHttpOverrides();

  late HttpServer server;
  late Directory tempDir;
  late _TestPaths paths;
  late DownloadManager downloader;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('download_test_');
    paths = _TestPaths(tempDir.path);
    downloader = DownloadManager(
      paths: paths,
      networkPolicy: _TestNetworkPolicy(),
      httpClient: HttpClient(),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DownloadManager unit tests', () {
    test('downloads Sherpa ONNX model and verifies SHA-256 integrity',
        () async {
      final dummyOnnxContent = utf8.encode('ONNX_MODEL_BINARY_MOCK_DATA_12345');
      final expectedSha = sha256.convert(dummyOnnxContent).toString();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.contentLength = dummyOnnxContent.length;
        request.response.add(dummyOnnxContent);
        request.response.close();
      });

      final manifest = LocalModelManifest(
        id: 'silero-vad',
        type: ModelType.vad,
        provider: 'sherpa-community',
        delivery: ModelDelivery.download,
        files: [
          ModelFile(
            name: 'silero_vad.onnx',
            url: 'http://${server.address.host}:${server.port}/silero_vad.onnx',
            sha256: expectedSha,
            sizeBytes: dummyOnnxContent.length,
          ),
        ],
      );

      final progressEvents = <ModelDownloadProgress>[];
      final targetDir = await downloader.download(
        manifest,
        onProgress: (p) => progressEvents.add(p),
      );

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.fraction, 1.0);
      expect(targetDir.path, contains('silero-vad'));

      final downloadedFile =
          File('${paths.downloadDir('silero-vad')}/silero_vad.onnx.part');
      expect(await downloadedFile.exists(), isTrue);
      expect(await downloadedFile.readAsBytes(), dummyOnnxContent);
    });

    test(
        'downloads E2B / LiteRT model through HTTP redirect with placeholder SHA',
        () async {
      final dummyModelContent =
          utf8.encode('LITERT_MODEL_BINARY_MOCK_DATA_E2B_GUTENBERG');

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) {
        if (request.uri.path == '/redirect') {
          request.response.redirect(Uri.parse(
              'http://${server.address.host}:${server.port}/target.litertlm'));
        } else {
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.contentLength = dummyModelContent.length;
          request.response.add(dummyModelContent);
          request.response.close();
        }
      });

      final manifest = LocalModelManifest(
        id: 'smollm2-360m-instruct',
        type: ModelType.llm,
        provider: 'google-gemma',
        delivery: ModelDelivery.download,
        files: [
          ModelFile(
            name: 'SmolLM2_360M_instruct.litertlm',
            url: 'http://${server.address.host}:${server.port}/redirect',
            sha256:
                '0000000000000000000000000000000000000000000000000000000000000000',
            sizeBytes: dummyModelContent.length,
          ),
        ],
      );

      final progressEvents = <ModelDownloadProgress>[];
      final targetDir = await downloader.download(
        manifest,
        onProgress: (p) => progressEvents.add(p),
      );

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.fraction, 1.0);
      expect(targetDir.path, contains('smollm2-360m-instruct'));

      final downloadedFile = File(
          '${paths.downloadDir('smollm2-360m-instruct')}/SmolLM2_360M_instruct.litertlm.part');
      expect(await downloadedFile.exists(), isTrue);
      expect(await downloadedFile.readAsBytes(), dummyModelContent);
    });

    test('supports resumable download with HTTP Range header', () async {
      final fullContent =
          utf8.encode('PART1_CONTENT_DATA___PART2_CONTENT_DATA_RESUMED');
      final part1Length = 20;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null && range.startsWith('bytes=')) {
          final start =
              int.parse(range.replaceFirst('bytes=', '').split('-').first);
          final bytes = fullContent.sublist(start);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.contentRangeHeader,
              'bytes $start-${fullContent.length - 1}/${fullContent.length}');
          request.response.headers.contentLength = bytes.length;
          request.response.add(bytes);
          request.response.close();
        } else {
          request.response.headers.contentLength = fullContent.length;
          request.response.add(fullContent);
          request.response.close();
        }
      });

      // Pre-seed a partial file and metadata
      final fileDir = paths.downloadDir('sherpa-asr');
      await Directory(fileDir).create(recursive: true);
      final partFile = File('$fileDir/model.tar.bz2.part');
      await partFile.writeAsBytes(fullContent.sublist(0, part1Length));

      final manifest = LocalModelManifest(
        id: 'sherpa-asr',
        type: ModelType.stt,
        provider: 'sherpa-community',
        delivery: ModelDelivery.download,
        files: [
          ModelFile(
            name: 'model.tar.bz2',
            url: 'http://${server.address.host}:${server.port}/model.tar.bz2',
            sha256:
                '0000000000000000000000000000000000000000000000000000000000000000',
            sizeBytes: fullContent.length,
          ),
        ],
      );

      final progressEvents = <ModelDownloadProgress>[];
      await downloader.download(
        manifest,
        onProgress: (p) => progressEvents.add(p),
      );

      expect(progressEvents, isNotEmpty);
      final downloadedFile = File('$fileDir/model.tar.bz2.part');
      expect(await downloadedFile.exists(), isTrue);
      expect(await downloadedFile.readAsBytes(), fullContent);
    });
  });
}
