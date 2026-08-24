/// In-memory fake VAD for unit tests.
library;

import '../audio/audio_frame.dart';
import '../config/component_configs.dart';
import '../vad/local_vad.dart';

/// Emits a started/ended pair around any non-empty audio.
class FakeVad implements LocalVad {
  bool _loaded = false;

  @override
  Future<void> load(VadConfig config) async {
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
  }

  @override
  Stream<VadEvent> analyze(Stream<AudioFrame> audio) async* {
    if (!_loaded) {
      throw StateError('FakeVad.analyze called before load()');
    }
    var sawAudio = false;
    DateTime? start;
    await for (final frame in audio) {
      if (!sawAudio) {
        sawAudio = true;
        start = frame.timestamp;
        yield VadSpeechStarted(timestamp: frame.timestamp, confidence: 1.0);
      }
    }
    if (sawAudio) {
      final ended = DateTime.now();
      yield VadSpeechEnded(
        timestamp: ended,
        speechDuration: ended.difference(start!),
      );
    }
  }
}
