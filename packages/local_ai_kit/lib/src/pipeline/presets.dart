/// Preset pipelines (architecture §5.4).
library;

import 'package:local_ai_core/local_ai_core.dart';

import '../facade/local_ai.dart';
import 'local_pipeline.dart';

/// One-liner pipelines for the common cases.
class LocalPipelinePresets {
  const LocalPipelinePresets();

  /// Text in → LLM → text deltas out.
  ///
  /// ```dart
  /// final chat = LocalPipeline.presets.textChat(ai).build();
  /// await for (final e in chat.run(textInput: 'Hi')) { ... }
  /// ```
  BuiltPipeline textChat(LocalAI ai, {String? systemPrompt}) =>
      LocalPipeline(ai)
          .input
          .text()
          .llm(systemPrompt: systemPrompt)
          .build();

  /// Microphone in → VAD → STT → transcript events out.
  BuiltPipeline transcription(LocalAI ai) =>
      LocalPipeline(ai).input.microphone().vad().stt().build();

  /// Full voice loop: Mic → VAD → STT → LLM → TTS → speaker.
  BuiltPipeline voiceChat(LocalAI ai, {String? systemPrompt, String? voiceId}) =>
      LocalPipeline(ai)
          .input
          .microphone()
          .vad()
          .stt()
          .llm(systemPrompt: systemPrompt)
          .tts(voiceId: voiceId)
          .output
          .speaker()
          .build();

  /// Voice command: Mic → VAD → STT → LLM with a structured-output schema
  /// (intent extraction), no TTS.
  BuiltPipeline voiceCommand(LocalAI ai, {required JsonSchema intentSchema}) =>
      LocalPipeline(ai)
          .input
          .microphone()
          .vad()
          .stt()
          .llm(
            systemPrompt: 'Extract the user intent as JSON matching the '
                'given schema. No prose.',
            responseSchema: intentSchema,
          )
          .build();
}
