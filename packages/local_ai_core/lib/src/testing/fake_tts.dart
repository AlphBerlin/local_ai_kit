/// In-memory fake TTS for unit tests.
library;

import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_chunk.dart';
import '../audio/audio_frame.dart';
import '../models/local_voice.dart';
import '../tts/local_tts.dart';

/// Synthesizes silence: one [AudioChunk] of zeros per [chunksPerRequest].
class FakeTts implements LocalTts {
  FakeTts({this.voices = const [], this.chunksPerRequest = 3});

  List<LocalVoice> voices;
  final int chunksPerRequest;
  bool _loaded = false;

  @override
  Future<void> load(TtsLoadOptions options) async {
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
  }

  @override
  List<LocalVoice> get installedVoices => List.unmodifiable(voices);

  @override
  Stream<AudioChunk> synthesizeStream(SpeakRequest request) async* {
    if (!_loaded) {
      throw StateError('FakeTts.synthesizeStream called before load()');
    }
    for (var i = 0; i < chunksPerRequest; i++) {
      yield AudioChunk(
        samples: Float32List(1600), // 100ms of silence @16kHz
        format: AudioFormat.pcm16kMono,
        isLast: i == chunksPerRequest - 1,
      );
    }
  }
}
