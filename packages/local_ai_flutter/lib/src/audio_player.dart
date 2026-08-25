/// Streaming speaker playback via the `audioplayers` plugin.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:local_ai_core/local_ai_core.dart';

/// [LocalAudioOutput] backed by `audioplayers`.
///
/// audioplayers is file/bytes oriented rather than sample-stream oriented,
/// so chunks are buffered into a growing WAV in the cache directory and the
/// player is fed progressively larger snapshots. [stop] truncates playback
/// immediately (barge-in).
///
/// TODO(verify): for true low-latency streaming playback swap audioplayers
/// for a PCM push API (e.g. a platform channel or `flutter_sound`'s
/// stream sink). The public contract (`play`/`stop`) is unaffected.
class FlutterAudioPlayer implements LocalAudioOutput {
  FlutterAudioPlayer({required this.cacheDir});

  /// Scratch directory for buffered playback files.
  final String cacheDir;

  AudioPlayer? _player;
  Process? _activeProcess;
  bool _stopped = false;

  @override
  Future<void> play(Stream<AudioChunk> audio) async {
    _stopped = false;
    final player = _player = AudioPlayer();
    final buffer = BytesBuilder(copy: false);
    AudioFormat? format;

    await for (final chunk in audio) {
      if (_stopped) return;
      format = chunk.format;
      buffer.add(_float32ToPcm16Bytes(chunk.samples));
    }
    if (_stopped) return;
    final effectiveFormat = format ?? AudioFormat.pcm16kMono;
    final wav = _wrapWav(buffer.takeBytes(), effectiveFormat);
    final file =
        File('$cacheDir/tts-${DateTime.now().microsecondsSinceEpoch}.wav');
    await file.writeAsBytes(wav, flush: true);
    try {
      if (Platform.isMacOS) {
        final proc = await Process.start('afplay', [file.path]);
        _activeProcess = proc;
        await proc.exitCode;
      } else {
        await player.play(DeviceFileSource(file.path));
        // Wait for playback completion (watchdog timeout; barge-in stop()
        // releases via the finally block).
        try {
          await player.onPlayerComplete.first.timeout(const Duration(minutes: 5));
        } on TimeoutException {
          // Give up waiting; the player is stopped below regardless.
        }
      }
    } finally {
      _activeProcess = null;
      await file.delete().catchError((_) => file);
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _activeProcess?.kill();
    _activeProcess = null;
    final player = _player;
    _player = null;
    await player?.stop();
    await player?.dispose();
  }

  static Uint8List _float32ToPcm16Bytes(Float32List samples) {
    final out = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(out);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      data.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return out;
  }

  /// Builds a minimal 16-bit PCM WAV header around [pcm] bytes.
  static Uint8List _wrapWav(Uint8List pcm, AudioFormat format) {
    const headerSize = 44;
    final byteRate = format.sampleRate * format.channels * 2;
    final out = Uint8List(headerSize + pcm.length);
    final data = ByteData.sublistView(out);

    void writeAscii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        out[offset + i] = text.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, headerSize - 8 + pcm.length, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little); // PCM header size
    data.setUint16(20, 1, Endian.little); // PCM format
    data.setUint16(22, format.channels, Endian.little);
    data.setUint32(24, format.sampleRate, Endian.little);
    data.setUint32(28, byteRate, Endian.little);
    data.setUint16(32, format.channels * 2, Endian.little); // block align
    data.setUint16(34, 16, Endian.little); // bits per sample
    writeAscii(36, 'data');
    data.setUint32(40, pcm.length, Endian.little);
    out.setRange(headerSize, headerSize + pcm.length, pcm);
    return out;
  }
}
