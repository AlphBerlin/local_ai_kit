/// Speech-to-text data models: transcripts, segments and stream events.
library;

/// One timed segment of a transcript.
class TranscriptSegment {
  const TranscriptSegment({
    required this.text,
    required this.start,
    required this.end,
    this.confidence = 1.0,
  });

  final String text;
  final Duration start;
  final Duration end;

  /// Recognizer confidence in [0, 1]; 1.0 when the engine does not report.
  final double confidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
        'confidence': confidence,
      };

  @override
  String toString() => 'TranscriptSegment("$text", $start-$end)';
}

/// A completed (final) transcription of an audio buffer or utterance.
class Transcript {
  const Transcript({
    required this.text,
    this.segments = const [],
    this.language,
  });

  /// Full recognized text.
  final String text;

  /// Timed segments when the recognizer provides them.
  final List<TranscriptSegment> segments;

  /// BCP-47 language tag when known / auto-detected.
  final String? language;

  bool get isEmpty => text.trim().isEmpty;

  @override
  String toString() =>
      'Transcript("$text"${language != null ? ', $language' : ''})';
}

/// Events emitted by `LocalStt.transcribeStream`.
sealed class TranscriptEvent {
  const TranscriptEvent();
}

/// Incremental, possibly-changing recognition hypothesis.
final class TranscriptPartial extends TranscriptEvent {
  const TranscriptPartial(this.text, {this.segment});

  final String text;
  final TranscriptSegment? segment;

  @override
  String toString() => 'TranscriptPartial("$text")';
}

/// Utterance finalized: text will no longer change.
final class TranscriptFinal extends TranscriptEvent {
  const TranscriptFinal(this.transcript);

  final Transcript transcript;

  @override
  String toString() => 'TranscriptFinal("$transcript")';
}
