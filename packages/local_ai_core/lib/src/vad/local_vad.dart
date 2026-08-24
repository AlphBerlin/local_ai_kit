/// Voice activity detection capability interface.
library;

import 'dart:async';
import '../audio/audio_frame.dart';
import '../config/component_configs.dart';

/// Events emitted by [LocalVad.analyze].
sealed class VadEvent {
  const VadEvent({required this.timestamp});

  /// Capture time of the frame that triggered the event.
  final DateTime timestamp;
}

/// Speech onset detected.
final class VadSpeechStarted extends VadEvent {
  const VadSpeechStarted({
    required super.timestamp,
    required this.confidence,
  });

  /// Speech probability at onset, in [0, 1].
  final double confidence;
}

/// Speech offset detected (after `minSilenceDurationMs` of silence).
final class VadSpeechEnded extends VadEvent {
  const VadSpeechEnded({
    required super.timestamp,
    required this.speechDuration,
  });

  /// Duration of the speech segment that just ended.
  final Duration speechDuration;
}

/// Continuous speech probability update (emitted per frame while active).
final class VadSpeechConfidence extends VadEvent {
  const VadSpeechConfidence({
    required super.timestamp,
    required this.confidence,
    required this.isSpeech,
  });

  final double confidence;
  final bool isSpeech;
}

/// On-device voice activity detection.
///
/// Implementation: `SherpaVadAdapter` (local_ai_sherpa, Silero VAD).
abstract interface class LocalVad {
  /// Loads the VAD model.
  Future<void> load(VadConfig config);

  /// Releases the VAD model.
  Future<void> unload();

  /// Analyzes a live audio stream and emits speech boundary / confidence
  /// events. The returned stream closes when [audio] closes.
  Stream<VadEvent> analyze(Stream<AudioFrame> audio);
}