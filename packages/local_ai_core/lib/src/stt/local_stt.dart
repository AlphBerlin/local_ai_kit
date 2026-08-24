/// On-device speech-to-text capability interface.
library;

import 'dart:async';
import '../audio/audio_frame.dart';
import 'transcript.dart';

/// Options for [LocalStt.load].
class SttLoadOptions {
  const SttLoadOptions({
    required this.modelId,
    this.language,
    this.enablePunctuation = true,
  });

  /// Catalog id of the recognition model.
  final String modelId;

  /// BCP-47 language tag; `null` = auto-detect when the model supports it.
  final String? language;

  /// Whether the recognizer should emit punctuated text.
  final bool enablePunctuation;
}

/// Per-request recognition options.
class SttOptions {
  const SttOptions({this.language, this.hotwords = const []});

  /// Overrides the language for this request only.
  final String? language;

  /// Domain words to bias recognition towards (e.g. contact names).
  final List<String> hotwords;
}

/// On-device speech recognition.
///
/// Implementation: `SherpaSttAdapter` (local_ai_sherpa).
abstract interface class LocalStt {
  /// Loads the recognition model.
  Future<void> load(SttLoadOptions options);

  /// Releases the recognizer.
  Future<void> unload();

  /// Streaming recognition: consumes live audio frames and emits
  /// [TranscriptPartial] hypotheses followed by a [TranscriptFinal] per
  /// utterance.
  Stream<TranscriptEvent> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  });

  /// One-shot recognition of a complete [audio] buffer.
  Future<Transcript> transcribe(AudioBuffer audio, {SttOptions? options});
}