/// Voice session event model (architecture §4.4, §5.3).
library;

import '../errors/local_ai_error.dart';

/// Why a voice turn was interrupted.
enum InterruptReason {
  /// The user started speaking over the assistant (barge-in).
  bargeIn,

  /// The session was cancelled programmatically.
  cancelled,

  /// The turn exceeded its time budget.
  timeout,
}

/// Events emitted on a `VoiceSession.events` broadcast stream.
sealed class VoiceEvent {
  const VoiceEvent();
}

/// Session is listening to the microphone.
final class VoiceListening extends VoiceEvent {
  const VoiceListening();
}

/// VAD detected speech onset.
final class VoiceSpeechStarted extends VoiceEvent {
  const VoiceSpeechStarted();
}

/// VAD detected speech offset; utterance goes to STT.
final class VoiceSpeechEnded extends VoiceEvent {
  const VoiceSpeechEnded();
}

/// Incremental transcript update from STT.
final class VoiceTranscriptUpdated extends VoiceEvent {
  const VoiceTranscriptUpdated({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

/// The LLM is generating (no tokens yet).
final class VoiceThinking extends VoiceEvent {
  const VoiceThinking();
}

/// The first LLM tokens arrived.
final class VoiceResponseStarted extends VoiceEvent {
  const VoiceResponseStarted();
}

/// Incremental assistant text.
final class VoiceResponseDelta extends VoiceEvent {
  const VoiceResponseDelta(this.textDelta);

  final String textDelta;
}

/// TTS is speaking (whole or part of the response).
final class VoiceSpeaking extends VoiceEvent {
  const VoiceSpeaking({this.text});

  /// The sentence currently being spoken, when known.
  final String? text;
}

/// The full turn completed successfully; session returns to listening.
final class VoiceFinished extends VoiceEvent {
  const VoiceFinished();
}

/// The turn was interrupted (see [reason]).
final class VoiceInterrupted extends VoiceEvent {
  const VoiceInterrupted({required this.reason});

  final InterruptReason reason;
}

/// A stage failed; the error is also surfaced, session may recover to
/// listening depending on severity.
final class VoiceErrorOccurred extends VoiceEvent {
  const VoiceErrorOccurred(this.error);

  final LocalAIError error;
}
