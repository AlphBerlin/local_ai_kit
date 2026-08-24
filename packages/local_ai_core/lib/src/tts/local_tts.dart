/// On-device text-to-speech capability interface.
library;

import 'dart:async';
import '../audio/audio_chunk.dart';
import '../models/local_voice.dart';

/// Options for [LocalTts.load].
class TtsLoadOptions {
  const TtsLoadOptions({
    required this.modelId,
    this.voiceId,
  });

  /// Catalog id of the TTS model.
  final String modelId;

  /// Voice to activate at load time; `null` = model default.
  final String? voiceId;
}

/// One synthesis request.
class SpeakRequest {
  const SpeakRequest({
    required this.text,
    this.voiceId,
    this.speed = 1.0,
    this.pitch = 1.0,
  });

  /// Text to synthesize. Long texts are chunked by the adapter so that
  /// time-to-first-audio stays low.
  final String text;

  /// Overrides the active voice for this request.
  final String? voiceId;

  /// Speaking rate multiplier, 1.0 = normal.
  final double speed;

  /// Pitch multiplier, 1.0 = normal.
  final double pitch;
}

/// On-device speech synthesis.
///
/// Implementation: `SherpaTtsAdapter` (local_ai_sherpa).
abstract interface class LocalTts {
  /// Loads the TTS model.
  Future<void> load(TtsLoadOptions options);

  /// Releases the model.
  Future<void> unload();

  /// Voices available locally right now (installed).
  List<LocalVoice> get installedVoices;

  /// Streams synthesized audio for [request]; playback can start on the
  /// first chunk.
  Stream<AudioChunk> synthesizeStream(SpeakRequest request);
}
