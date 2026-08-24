/// Silero VAD via sherpa_onnx, running in a worker isolate.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

import 'isolate/sherpa_worker.dart';

/// [LocalVad] backed by sherpa_onnx's Silero VAD.
class SherpaVadAdapter implements LocalVad {
  SherpaVadAdapter({required LocalStoragePaths paths}) : _paths = paths;

  static const String provider = ModelProviders.sherpaCommunity;

  final LocalStoragePaths _paths;
  SherpaWorker? _worker;

  @override
  Future<void> load(VadConfig config) async {
    final modelPath =
        '${_paths.modelDir(ModelType.vad, config.modelId)}/silero_vad.onnx';
    final worker = _worker = await SherpaWorker.spawn(_vadWorkerEntry);
    final ok = await worker.request('initVad', payload: <String, Object?>{
      'modelPath': modelPath,
      'threshold': config.threshold,
      'minSpeechDurationMs': config.minSpeechDurationMs,
      'minSilenceDurationMs': config.minSilenceDurationMs,
      'sampleRate': config.sampleRate,
    });
    if (ok != true) {
      throw NativeRuntimeError('Silero VAD failed to initialize: $ok');
    }
  }

  @override
  Future<void> unload() async {
    _worker?.dispose();
    _worker = null;
  }

  @override
  Stream<VadEvent> analyze(Stream<AudioFrame> audio) {
    final worker = _worker;
    if (worker == null) {
      return Stream.error(const InvalidStateError(
          'SherpaVadAdapter: analyze called before load().'));
    }
    late StreamController<VadEvent> controller;
    StreamSubscription<AudioFrame>? audioSub;
    StreamSubscription<SherpaWorkerEvent>? eventSub;

    controller = StreamController<VadEvent>(onListen: () {
      eventSub = worker.events.listen((event) {
        switch (event.kind) {
          case 'speechStart':
            controller.add(VadSpeechStarted(
              timestamp: DateTime.now(),
              confidence: (event.data as num?)?.toDouble() ?? 1.0,
            ));
          case 'speechEnd':
            controller.add(VadSpeechEnded(
              timestamp: DateTime.now(),
              speechDuration:
                  Duration(milliseconds: (event.data as num?)?.toInt() ?? 0),
            ));
          case 'confidence':
            final map = (event.data as Map).cast<String, Object?>();
            controller.add(VadSpeechConfidence(
              timestamp: DateTime.now(),
              confidence: (map['p'] as num).toDouble(),
              isSpeech: map['s'] as bool,
            ));
          case 'error':
            controller.addError(event.data ?? const NativeRuntimeError('vad'));
        }
      });
      audioSub = audio.listen(
        (frame) {
          // TODO(verify): real-time downlink backpressure — drop frames when
          // the worker falls behind instead of buffering unboundedly.
          worker.sendFrame(frame.samples);
        },
        onDone: () => controller.close(),
        onError: controller.addError,
      );
    }, onCancel: () async {
      await audioSub?.cancel();
      await eventSub?.cancel();
    });

    return controller.stream;
  }

  // ---------------------------------------------------------------------------
  // Worker isolate side — sherpa_onnx lives only below this line.
  // ---------------------------------------------------------------------------

  static void _vadWorkerEntry(SendPort mainPort) {
    _VadWorkerLoop(mainPort).run();
  }
}

class _VadWorkerLoop extends SherpaWorkerLoop {
  _VadWorkerLoop(super.mainPort);

  // TODO(verify): sherpa_onnx API — Vad + SileroVadModelConfig creation.
  dynamic _vad; // sherpa_onnx.Vad

  @override
  Future<void> onCommand(SherpaCommand command) async {
    switch (command.op) {
      case 'initVad':
        // ignore: unused_local_variable
        final args = (command.payload as Map).cast<String, Object?>();
        // TODO(verify): sherpa_onnx API.
        // final config = sherpa.VadModelConfig(
        //   sileroVad: sherpa.SileroVadModelConfig(
        //     model: args['modelPath'] as String,
        //     threshold: (args['threshold'] as num).toDouble(),
        //     minSpeechDuration: ...,
        //     minSilenceDuration: ...,
        //   ),
        //   sampleRate: args['sampleRate'] as int,
        // );
        // _vad = sherpa.Vad(config);
        _vad = Object(); // placeholder until sherpa_onnx wiring is verified
        reply(command, true);
    }
  }

  @override
  Future<void> onFrame(Float32List samples) async {
    final vad = _vad;
    if (vad == null) return;
    // TODO(verify): sherpa_onnx API — acceptWaveform + event polling.
    // vad.acceptWaveform(samples);
    // while (!vad.isEmpty()) { final seg = vad.front(); vad.pop(); ... }
    // if (vad.isSpeechDetected() && !_inSpeech) emit('speechStart', ...)
  }

  @override
  Future<void> onShutdown() async {
    // TODO(verify): sherpa_onnx API — release native VAD resources.
    _vad = null;
  }
}
