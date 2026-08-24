/// SenseVoice (sherpa_onnx) streaming STT adapter.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

import 'isolate/sherpa_worker.dart';

/// [LocalStt] backed by sherpa_onnx (SenseVoice Small etc.).
class SherpaSttAdapter implements LocalStt {
  SherpaSttAdapter({required LocalStoragePaths paths}) : _paths = paths;

  static const String provider = ModelProviders.sherpaCommunity;

  final LocalStoragePaths _paths;
  SherpaWorker? _worker;
  SttLoadOptions? _options;

  @override
  Future<void> load(SttLoadOptions options) async {
    _options = options;
    final modelDir = _paths.modelDir(ModelType.stt, options.modelId);
    final worker = _worker = await SherpaWorker.spawn(_sttWorkerEntry);
    final ok = await worker.request('initRecognizer', payload: <String, Object?>{
      'modelPath': '$modelDir/model.int8.onnx',
      'tokensPath': '$modelDir/tokens.txt',
      'language': options.language,
      'enablePunctuation': options.enablePunctuation,
    });
    if (ok != true) {
      throw NativeRuntimeError('SenseVoice recognizer failed to init: $ok');
    }
  }

  @override
  Future<void> unload() async {
    _worker?.dispose();
    _worker = null;
  }

  @override
  Stream<TranscriptEvent> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) {
    final worker = _worker;
    if (worker == null) {
      return Stream.error(const InvalidStateError(
          'SherpaSttAdapter: transcribeStream called before load().'));
    }
    late StreamController<TranscriptEvent> controller;
    StreamSubscription<AudioFrame>? audioSub;
    StreamSubscription<SherpaWorkerEvent>? eventSub;

    controller = StreamController<TranscriptEvent>(onListen: () {
      eventSub = worker.events.listen((event) {
        switch (event.kind) {
          case 'partial':
            controller.add(TranscriptPartial(event.data as String? ?? ''));
          case 'final':
            controller.add(TranscriptFinal(
                Transcript(text: event.data as String? ?? '')));
          case 'error':
            controller.addError(event.data ?? const NativeRuntimeError('stt'));
        }
      });
      worker.send('startUtterance');
      audioSub = audio.listen(
        worker.sendFrame,
        onDone: () async {
          worker.send('endUtterance');
          await controller.close();
        },
        onError: controller.addError,
      );
    }, onCancel: () async {
      await audioSub?.cancel();
      await eventSub?.cancel();
    });

    return controller.stream;
  }

  @override
  Future<Transcript> transcribe(AudioBuffer audio, {SttOptions? options}) async {
    final worker = _worker;
    if (worker == null) {
      throw const InvalidStateError(
          'SherpaSttAdapter: transcribe called before load().');
    }
    final result = await worker.request('decodeBuffer', payload: {
      'samples': TransferableTypedData.fromList([audio.samples]),
      'sampleRate': audio.format.sampleRate,
    });
    return Transcript(text: result as String? ?? '');
  }

  static void _sttWorkerEntry(SendPort mainPort) {
    _SttWorkerLoop(mainPort).run();
  }
}

class _SttWorkerLoop extends SherpaWorkerLoop {
  _SttWorkerLoop(super.mainPort);

  // TODO(verify): sherpa_onnx API — OnlineRecognizer + OnlineStream.
  dynamic _recognizer;
  dynamic _stream;

  @override
  Future<void> onCommand(SherpaCommand command) async {
    switch (command.op) {
      case 'initRecognizer':
        final args = (command.payload as Map).cast<String, Object?>();
        // TODO(verify): sherpa_onnx API.
        // final config = sherpa.OnlineRecognizerConfig(
        //   model: sherpa.OnlineModelConfig(
        //     senseVoice: sherpa.OnlineSenseVoiceModelConfig(
        //       model: args['modelPath'] as String,
        //     ),
        //     tokens: args['tokensPath'] as String,
        //   ),
        // );
        // _recognizer = sherpa.OnlineRecognizer(config);
        _recognizer = Object();
        reply(command, true);
      case 'startUtterance':
        // TODO(verify): sherpa_onnx API — _recognizer.createStream().
        _stream = Object();
      case 'endUtterance':
        // TODO(verify): flush stream, emit final result event.
        _stream = null;
      case 'decodeBuffer':
        final args = (command.payload as Map).cast<String, Object?>();
        final samples =
            (args['samples'] as TransferableTypedData).materialize().asFloat32List();
        // TODO(verify): sherpa_onnx API — OfflineRecognizer decode.
        reply(command, 'decoded ${samples.length} samples (placeholder)');
    }
  }

  @override
  Future<void> onFrame(Float32List samples) async {
    if (_stream == null) return;
    // TODO(verify): sherpa_onnx API.
    // _stream.acceptWaveform(samples, sampleRate: 16000);
    // while (_recognizer.isReady(_stream)) { _recognizer.decode(_stream); }
    // final text = _recognizer.getResult(_stream).text;
    // if (text changed) emit('partial', data: text);
    // if (_recognizer.isEndpoint(_stream)) { emit('final', ...); _recognizer.reset(_stream); }
  }

  @override
  Future<void> onShutdown() async {
    // TODO(verify): sherpa_onnx API — release recognizer/stream.
    _stream = null;
    _recognizer = null;
  }
}
