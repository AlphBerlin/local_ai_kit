/// In-memory fake STT for unit tests.
library;

import 'dart:async';
import '../../audio/audio_frame.dart';
import '../../stt/local_stt.dart';
import '../../stt/transcript.dart';

/// Returns a scripted transcript regardless of audio content.
class FakeStt implements LocalStt {
  FakeStt({this.transcriptText = 'fake transcript'});

  String transcriptText;
  bool _loaded = false;

  @override
  Future<void> load(SttLoadOptions options) async {
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
  }

  @override
  Stream<TranscriptEvent> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) async* {
    if (!_loaded) {
      throw StateError('FakeStt.transcribeStream called before load()');
    }
    // Drain the audio so upstream sources complete naturally.
    await for (final _ in audio) {}
    yield TranscriptPartial(transcriptText);
    yield TranscriptFinal(Transcript(text: transcriptText));
  }

  @override
  Future<Transcript> transcribe(AudioBuffer audio, {SttOptions? options}) async {
    if (!_loaded) {
      throw StateError('FakeStt.transcribe called before load()');
    }
    return Transcript(text: transcriptText);
  }
}