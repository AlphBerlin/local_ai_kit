/// Generic pipeline event model emitted by `BuiltPipeline.run()`.
library;

import '../audio/audio_chunk.dart';
import '../errors/local_ai_error.dart';

/// Events produced by running a `LocalPipeline`.
sealed class PipelineEvent {
  const PipelineEvent();
}

/// Audio capture started.
final class PipelineInputStarted extends PipelineEvent {
  const PipelineInputStarted();
}

/// VAD detected speech inside the pipeline.
final class PipelineVadSpeech extends PipelineEvent {
  const PipelineVadSpeech({required this.started});

  /// True on speech onset, false on offset.
  final bool started;
}

/// A transcript (partial or final) is available.
final class PipelineTranscript extends PipelineEvent {
  const PipelineTranscript({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

/// An LLM text delta is available.
final class PipelineLlmDelta extends PipelineEvent {
  const PipelineLlmDelta(this.textDelta);

  final String textDelta;
}

/// A chunk of synthesized audio was emitted (also routed to the output
/// stage when configured).
final class PipelineAudioChunk extends PipelineEvent {
  const PipelineAudioChunk(this.chunk);

  final AudioChunk chunk;
}

/// The pipeline completed one full pass.
final class PipelineCompleted extends PipelineEvent {
  const PipelineCompleted();
}

/// A stage failed.
final class PipelineError extends PipelineEvent {
  const PipelineError(this.error);

  final LocalAIError error;
}
