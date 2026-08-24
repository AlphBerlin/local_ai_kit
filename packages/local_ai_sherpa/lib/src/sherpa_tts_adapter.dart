/// sherpa_onnx TTS adapter (Supertonic etc.).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

import 'isolate/sherpa_worker.dart';

/// [LocalTts] backed by sherpa_onnx.
class SherpaTtsAdapter implements LocalTts {
  SherpaTtsAdapter({required LocalStoragePaths paths}) : _paths = paths;

  static const String provider = ModelProviders.sherpaCommunity;

  final LocalStoragePaths _paths;
  SherpaWorker? _worker;
  LocalModelManifest? _manifest;
  String? _activeVoiceId;

  /// Attaches the resolved manifest so [installedVoices] can be served and
  /// voice ids validated. Called by the kit during wiring.
  void attachManifest(LocalModelManifest manifest) {
    _manifest = manifest;
  }

  @override
  Future<void> load(TtsLoadOptions options) async {
    final modelDir = _paths.modelDir(ModelType.tts, options.modelId);
    _activeVoiceId = options.voiceId;
    final worker = _worker = await SherpaWorker.spawn(_ttsWorkerEntry);
    final ok = await worker.request('initTts', payload: <String, Object?>{
      'modelPath': '$modelDir/supertonic.onnx',
      'voiceDir':
          options.voiceId != null ? _paths.voiceDir(options.voiceId!) : null,
    });
    if (ok != true) {
      throw NativeRuntimeError('TTS failed to initialize: $ok');
    }
  }

  @override
  Future<void> unload() async {
    _worker?.dispose();
    _worker = null;
  }

  @override
  List<LocalVoice> get installedVoices {
    final voices = _manifest?.voices ?? const <LocalVoice>[];
    return voices.where((voice) {
      // A voice is "installed" when all of its files exist on disk.
      final dir = _paths.voiceDir(voice.id);
      return voice.files.isEmpty ||
          voice.files.isNotEmpty && _voiceFilesExist(dir, voice);
    }).toList(growable: false);
  }

  bool _voiceFilesExist(String dir, LocalVoice voice) {
    // Deferred to dart:io at call time; kept sync deliberately because
    // LocalTts.installedVoices is a sync getter in core.
    try {
      return voice.files.every((f) => FileSystemEntity.isFileSync(
          '$dir/${f.relativePath != null ? '${f.relativePath}/' : ''}${f.name}'));
    } on Object {
      return false;
    }
  }

  @override
  Stream<AudioChunk> synthesizeStream(SpeakRequest request) {
    final worker = _worker;
    if (worker == null) {
      return Stream.error(const InvalidStateError(
          'SherpaTtsAdapter: synthesizeStream called before load().'));
    }
    late StreamController<AudioChunk> controller;
    StreamSubscription<SherpaWorkerEvent>? eventSub;

    controller = StreamController<AudioChunk>(onListen: () {
      eventSub = worker.events.listen((event) {
        switch (event.kind) {
          case 'audio':
            final data = (event.data as TransferableTypedData)
                .materialize()
                .asFloat32List();
            controller.add(AudioChunk(
              samples: data,
              format: AudioFormat.pcm22kMonoFloat,
            ));
          case 'done':
            controller.add(AudioChunk(
              samples: Float32List(0),
              format: AudioFormat.pcm22kMonoFloat,
              isLast: true,
            ));
            controller.close();
          case 'error':
            controller.addError(event.data ?? const NativeRuntimeError('tts'));
        }
      });
      // Sentence-level chunking keeps time-to-first-audio low.
      for (final sentence in _splitSentences(request.text)) {
        worker.send('synthesize', payload: <String, Object?>{
          'text': sentence,
          'voiceId': request.voiceId ?? _activeVoiceId,
          'speed': request.speed,
          'pitch': request.pitch,
        });
      }
      worker.send('flush');
    }, onCancel: () async {
      worker.send('cancelSynthesis');
      await eventSub?.cancel();
    });

    return controller.stream;
  }

  /// Splits [text] into sentence-ish chunks for low-latency synthesis.
  static List<String> _splitSentences(String text) {
    final parts = text
        .split(RegExp(r'(?<=[.!?。!?\n])\s*'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? [text] : parts;
  }

  static void _ttsWorkerEntry(SendPort mainPort) {
    _TtsWorkerLoop(mainPort).run();
  }
}

class _TtsWorkerLoop extends SherpaWorkerLoop {
  _TtsWorkerLoop(super.mainPort);

  // TODO(verify): sherpa_onnx API — OfflineTts.
  dynamic _tts;

  @override
  Future<void> onCommand(SherpaCommand command) async {
    switch (command.op) {
      case 'initTts':
        // ignore: unused_local_variable
        final args = (command.payload as Map).cast<String, Object?>();
        // TODO(verify): sherpa_onnx API.
        // final config = sherpa.OfflineTtsConfig(
        //   model: sherpa.OfflineTtsModelConfig(...args['modelPath']...),
        // );
        // _tts = sherpa.OfflineTts(config);
        _tts = Object();
        reply(command, true);
      case 'synthesize':
        final args = (command.payload as Map).cast<String, Object?>();
        final text = args['text'] as String;
        if (_tts == null) return;
        // TODO(verify): sherpa_onnx API — streaming generation callback:
        // _tts.generate(text, callback: (Float32List chunk) {
        //   emit('audio', data: TransferableTypedData.fromList([chunk]));
        // });
        emit('audio',
            data: TransferableTypedData.fromList(
                [Float32List(text.length * 100)]));
      case 'flush':
        emit('done');
      case 'cancelSynthesis':
        // TODO(verify): cooperative cancellation of in-flight synthesis.
        break;
    }
  }

  @override
  Future<void> onFrame(Float32List samples) async {
    // TTS worker receives no audio input.
  }

  @override
  Future<void> onShutdown() async {
    // TODO(verify): sherpa_onnx API — release TTS resources.
    _tts = null;
  }
}
