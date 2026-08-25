/// Float32-to-PCM conversion shared by streaming playback backends.
library;

import 'dart:typed_data';

import 'package:local_ai_core/local_ai_core.dart';

/// Converts normalized float samples into little-endian signed 16-bit PCM.
Uint8List float32ToPcm16Bytes(Float32List samples) {
  final out = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i].clamp(-1.0, 1.0);
    data.setInt16(i * 2, (sample * 32767).round(), Endian.little);
  }
  return out;
}

/// Converts a stream of [AudioChunk]s into PCM byte blocks without buffering
/// the utterance in memory.
Stream<Uint8List> pcm16Stream(Stream<AudioChunk> audio) async* {
  await for (final chunk in audio) {
    if (chunk.samples.isNotEmpty) yield float32ToPcm16Bytes(chunk.samples);
  }
}
