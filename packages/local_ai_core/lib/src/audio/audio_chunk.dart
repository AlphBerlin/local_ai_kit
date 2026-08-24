/// Streaming synthesis output unit.
library;

import 'dart:typed_data';

import 'audio_frame.dart';

/// One chunk of synthesized audio, emitted by [LocalTts.synthesizeStream] and
/// consumed by [LocalAudioOutput.play].
class AudioChunk {
  const AudioChunk({
    required this.samples,
    required this.format,
    this.isLast = false,
  });

  /// Sample values in [-1.0, 1.0].
  final Float32List samples;
  final AudioFormat format;

  /// True on the terminal chunk of an utterance.
  final bool isLast;

  int get sampleCount => samples.length;

  Duration get duration => Duration(
        microseconds: (samples.length / format.channels) *
            Duration.microsecondsPerSecond ~/
            format.sampleRate,
      );

  @override
  String toString() =>
      'AudioChunk(${samples.length} samples @ ${format.sampleRate}Hz${isLast ? ', last' : ''})';
}
