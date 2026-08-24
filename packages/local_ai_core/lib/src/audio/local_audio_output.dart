/// Speaker / audio output abstraction.
library;

import 'dart:async';
import 'audio_chunk.dart';

/// Plays back synthesized audio.
///
/// Implemented by `FlutterAudioPlayer` in `local_ai_flutter`. Playback must
/// be streaming (chunks are played as they arrive) to keep time-to-first-
/// audio low in voice sessions.
abstract interface class LocalAudioOutput {
  /// Plays [audio] chunks as they arrive.
  ///
  /// Completes when the stream is done **and** the last chunk has finished
  /// playing.
  Future<void> play(Stream<AudioChunk> audio);

  /// Immediately truncates playback (barge-in). Safe to call when idle.
  Future<void> stop();
}