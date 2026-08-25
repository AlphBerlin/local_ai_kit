import 'dart:async';
import 'dart:isolate';
import 'dart:math';
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

  double _threshold = 0.0035;
  int _minSpeechDurationMs = 120;
  int _minSilenceDurationMs = 850;
  int _sampleRate = 16000;

  bool _inSpeech = false;
  DateTime? _speechStartTime;
  double _noiseFloor = 0.001;
  int _consecutiveSpeechFrames = 0;
  int _consecutiveSilenceFrames = 0;

  @override
  Future<void> onCommand(SherpaCommand command) async {
    switch (command.op) {
      case 'initVad':
        final args = (command.payload as Map).cast<String, Object?>();
        _threshold = ((args['threshold'] as num?)?.toDouble() ?? 0.5) * 0.007;
        if (_threshold < 0.003) _threshold = 0.003;
        _minSpeechDurationMs =
            (args['minSpeechDurationMs'] as num?)?.toInt() ?? 120;
        _minSilenceDurationMs =
            (args['minSilenceDurationMs'] as num?)?.toInt() ?? 850;
        _sampleRate = (args['sampleRate'] as num?)?.toInt() ?? 16000;
        _inSpeech = false;
        _speechStartTime = null;
        _noiseFloor = 0.001;
        _consecutiveSpeechFrames = 0;
        _consecutiveSilenceFrames = 0;
        reply(command, true);
    }
  }

  @override
  Future<void> onFrame(Float32List samples) async {
    if (samples.isEmpty) return;

    // Calculate frame RMS (root mean square) energy
    var sumSq = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      sumSq += s * s;
    }
    final rms = sqrt(sumSq / samples.length);

    // Adaptive noise floor tracking
    if (rms < _noiseFloor) {
      _noiseFloor = _noiseFloor * 0.85 + rms * 0.15;
    } else {
      _noiseFloor = _noiseFloor * 0.999 + rms * 0.001;
    }

    // Dynamic threshold based on noise floor + sensitivity
    final activeThreshold = max(_threshold, _noiseFloor * 1.5);
    final isSpeechFrame = rms > activeThreshold;
    final confidence =
        ((rms - _noiseFloor) / (activeThreshold * 2)).clamp(0.0, 1.0);

    final frameDurationMs = max(1, (samples.length * 1000) ~/ _sampleRate);
    final speechTriggerFrames =
        max(1, _minSpeechDurationMs ~/ max(1, frameDurationMs));
    final silenceTriggerFrames =
        max(2, _minSilenceDurationMs ~/ max(1, frameDurationMs));

    if (isSpeechFrame) {
      _consecutiveSpeechFrames++;
      _consecutiveSilenceFrames = 0;

      if (!_inSpeech && _consecutiveSpeechFrames >= speechTriggerFrames) {
        _inSpeech = true;
        _speechStartTime = DateTime.now();
        emit('speechStart', data: confidence > 0 ? confidence : 0.85);
      } else if (_inSpeech) {
        emit('confidence', data: {'p': confidence, 's': true});
      }
    } else {
      _consecutiveSpeechFrames = 0;
      if (_inSpeech) {
        _consecutiveSilenceFrames++;
        if (_consecutiveSilenceFrames >= silenceTriggerFrames) {
          _inSpeech = false;
          final durationMs = _speechStartTime != null
              ? DateTime.now().difference(_speechStartTime!).inMilliseconds
              : 0;
          emit('speechEnd', data: durationMs);
          emit('confidence', data: {'p': 0.0, 's': false});
          _consecutiveSilenceFrames = 0;
          _speechStartTime = null;
        } else {
          emit('confidence', data: {'p': confidence, 's': false});
        }
      }
    }
  }

  @override
  Future<void> onShutdown() async {
    _inSpeech = false;
  }
}
