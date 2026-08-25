/// Audio primitives shared by VAD / STT / TTS and the platform layer.
library;

import 'dart:typed_data';

/// Canonical capture formats.
///
/// The default everywhere is [AudioFormat.pcm16kMono]: 16 kHz, mono,
/// float32 samples normalized to [-1, 1] — what Silero VAD and sherpa
/// recognizers expect.
enum AudioFormat {
  /// 16 kHz mono float32 (default; VAD/STT friendly).
  pcm16kMono(16000, 1, AudioEncoding.float32),

  /// 16 kHz mono signed 16-bit PCM.
  pcm16kMonoInt16(16000, 1, AudioEncoding.int16),

  /// 44.1 kHz mono float32 (Supertonic TTS / HD playback quality).
  pcm44kMonoFloat(44100, 1, AudioEncoding.float32),

  /// 24 kHz mono float32 (Kokoro TTS native output rate).
  pcm24kMonoFloat(24000, 1, AudioEncoding.float32),

  /// 22.05 kHz mono float32 (Piper/VITS typical TTS output rate).
  pcm22kMonoFloat(22050, 1, AudioEncoding.float32);

  const AudioFormat(this.sampleRate, this.channels, this.encoding);

  final int sampleRate;
  final int channels;
  final AudioEncoding encoding;
}

enum AudioEncoding { float32, int16 }

/// One frame of captured or synthesized audio.
///
/// Samples are always float32 in [-1, 1]; integer capture is converted at
/// the platform boundary so downstream (VAD/STT) never deals with encodings.
class AudioFrame {
  const AudioFrame({
    required this.samples,
    required this.format,
    required this.timestamp,
    this.sequence = 0,
  });

  /// Sample values in [-1.0, 1.0], interleaved if multi-channel.
  final Float32List samples;

  /// Capture format of this frame.
  final AudioFormat format;

  /// Capture time (wall clock) of the first sample.
  final DateTime timestamp;

  /// Monotonic frame counter from the source, starting at 0.
  final int sequence;

  int get sampleCount => samples.length;

  Duration get duration => Duration(
        microseconds: (samples.length / format.channels) *
            Duration.microsecondsPerSecond ~/
            format.sampleRate,
      );

  @override
  String toString() =>
      'AudioFrame(${samples.length} samples @ ${format.sampleRate}Hz, seq=$sequence)';
}

/// A contiguous, seekable block of audio (e.g. one utterance) handed to
/// one-shot [LocalStt.transcribe].
class AudioBuffer {
  AudioBuffer({required this.samples, required this.format});

  /// All samples of the buffer.
  final Float32List samples;
  final AudioFormat format;

  Duration get duration => Duration(
        microseconds: (samples.length / format.channels) *
            Duration.microsecondsPerSecond ~/
            format.sampleRate,
      );

  /// Builds a buffer by concatenating [frames].
  factory AudioBuffer.fromFrames(List<AudioFrame> frames) {
    if (frames.isEmpty) {
      return AudioBuffer(
        samples: Float32List(0),
        format: AudioFormat.pcm16kMono,
      );
    }
    final format = frames.first.format;
    final total = frames.fold<int>(0, (sum, f) => sum + f.samples.length);
    final out = Float32List(total);
    var offset = 0;
    for (final frame in frames) {
      out.setRange(offset, offset + frame.samples.length, frame.samples);
      offset += frame.samples.length;
    }
    return AudioBuffer(samples: out, format: format);
  }
}
