/// Microphone capture via the `record` plugin.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';
import 'package:record/record.dart';

import 'permission_gate.dart';

/// [LocalAudioSource] backed by the device microphone.
///
/// Produces float32 frames at the requested [AudioFormat]; integer PCM
/// capture is converted at this boundary so VAD/STT never see encodings.
class FlutterAudioRecorder implements LocalAudioSource {
  FlutterAudioRecorder({PermissionGate? permissionGate})
      : _permissionGate = permissionGate ?? PermissionGate();

  final PermissionGate _permissionGate;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;

  @override
  Stream<AudioFrame> start({AudioFormat format = AudioFormat.pcm16kMono}) {
    late StreamController<AudioFrame> controller;
    var sequence = 0;

    controller = StreamController<AudioFrame>(onListen: () async {
      await _permissionGate.ensureMicrophone();
      final recorder = _recorder = AudioRecorder();

      // TODO(verify): record plugin stream config API (AudioRecorder +
      // RecordConfig with encoder pcm16bits gives a PCM byte stream).
      final byteStream = await recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: format.sampleRate,
        numChannels: format.channels,
      ));

      _subscription = byteStream.listen(
        (bytes) {
          final samples = _bytesToFloat32(bytes);
          controller.add(AudioFrame(
            samples: samples,
            format: AudioFormat.pcm16kMono,
            timestamp: DateTime.now(),
            sequence: sequence++,
          ));
        },
        onError: controller.addError,
        onDone: () => controller.close(),
      );
    }, onCancel: () async {
      await stop();
      await controller.close();
    });

    return controller.stream;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      await recorder.stop();
      await recorder.dispose();
    }
  }

  /// Converts little-endian PCM16 bytes to float32 samples in [-1, 1].
  static Float32List _bytesToFloat32(Uint8List bytes) {
    final usable = bytes.length - (bytes.length % 2);
    final out = Float32List(usable ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < out.length; i++) {
      final value = data.getInt16(i * 2, Endian.little);
      out[i] = value / 32768.0;
    }
    return out;
  }
}
