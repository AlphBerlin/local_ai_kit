/// Typed pipeline DSL (architecture §5.4).
///
/// Every builder method returns a new stage type, so illegal orderings are
/// compile-time errors:
/// ```dart
/// final pipeline = LocalPipeline(ai)
///     .input.microphone()
///     .vad()
///     .stt()
///     .llm(systemPrompt: 'You are helpful.')
///     .tts()
///     .output.speaker()
///     .build();
/// await for (final event in pipeline.run()) { ... }
/// ```
library;

import 'dart:async';

import 'package:local_ai_core/local_ai_core.dart';

import '../facade/local_ai.dart';

/// Entry point of the builder chain (via `LocalAI.pipeline()`).
class LocalPipeline {
  LocalPipeline(this._ai);

  final LocalAI _ai;

  PipelineInputSelector get input => PipelineInputSelector._(_ai);

  /// Preset pipelines (architecture §5.4).
  static LocalPipelinePresets get presets => const LocalPipelinePresets();
}

/// First stage: pick the pipeline input.
class PipelineInputSelector {
  PipelineInputSelector._(this._ai);

  final LocalAI _ai;

  /// Microphone input (streaming audio frames).
  MicStage microphone() => MicStage._(_ai);

  /// Text input passed to `run(textInput: ...)` at execution time.
  TextStage text() => TextStage._(_ai, usesTextInput: true);
}

/// After `.microphone()`: audio may be analyzed or transcribed.
class MicStage {
  MicStage._(this._ai);

  final LocalAI _ai;

  /// Adds VAD-based utterance segmentation.
  VadStage vad() => VadStage._(_ai);
}

/// After `.vad()`: utterances can be transcribed.
class VadStage {
  VadStage._(this._ai);

  final LocalAI _ai;

  /// Adds streaming speech-to-text over VAD-segmented utterances.
  TextStage stt() => TextStage._(_ai, usesTextInput: false);
}

/// After `.stt()` (or `.text()`): text can be transformed by an LLM or end
/// the pipeline.
class TextStage {
  TextStage._(this._ai, {required this.usesTextInput});

  final LocalAI _ai;
  final bool usesTextInput;

  /// Adds LLM generation over the transcript / text input.
  LlmStage llm({String? systemPrompt, JsonSchema? responseSchema}) =>
      LlmStage._(_ai,
          usesTextInput: usesTextInput,
          systemPrompt: systemPrompt,
          responseSchema: responseSchema);

  /// Ends the pipeline after STT (transcription pipelines).
  BuiltPipeline build() => BuiltPipeline._(_PipelineSpec(
        ai: _ai,
        usesTextInput: usesTextInput,
        hasLlm: false,
        hasTts: false,
      ));
}

/// After `.llm()`: text can be spoken or end the pipeline.
class LlmStage {
  LlmStage._(
    this._ai, {
    required this.usesTextInput,
    this.systemPrompt,
    this.responseSchema,
  });

  final LocalAI _ai;
  final bool usesTextInput;
  final String? systemPrompt;
  final JsonSchema? responseSchema;

  /// Adds TTS synthesis of the LLM response.
  TtsStage tts({String? voiceId}) => TtsStage._(
        _ai,
        usesTextInput: usesTextInput,
        systemPrompt: systemPrompt,
        responseSchema: responseSchema,
        voiceId: voiceId,
      );

  /// Ends the pipeline after the LLM (text output pipelines).
  BuiltPipeline build() => BuiltPipeline._(_PipelineSpec(
        ai: _ai,
        usesTextInput: usesTextInput,
        hasLlm: true,
        systemPrompt: systemPrompt,
        responseSchema: responseSchema,
      ));
}

/// After `.tts()`: choose where the audio goes.
class TtsStage {
  TtsStage._(
    this._ai, {
    required this.usesTextInput,
    this.systemPrompt,
    this.responseSchema,
    this.voiceId,
  });

  final LocalAI _ai;
  final bool usesTextInput;
  final String? systemPrompt;
  final JsonSchema? responseSchema;
  final String? voiceId;

  PipelineOutputSelector get output => PipelineOutputSelector._(
        _ai,
        usesTextInput: usesTextInput,
        systemPrompt: systemPrompt,
        responseSchema: responseSchema,
        voiceId: voiceId,
      );
}

/// Output routing for audio pipelines.
class PipelineOutputSelector {
  PipelineOutputSelector._(
    this._ai, {
    required this.usesTextInput,
    this.systemPrompt,
    this.responseSchema,
    this.voiceId,
  });

  final LocalAI _ai;
  final bool usesTextInput;
  final String? systemPrompt;
  final JsonSchema? responseSchema;
  final String? voiceId;

  /// Plays synthesized audio through the device speaker.
  BuiltPipeline speaker() => BuiltPipeline._(_PipelineSpec(
        ai: _ai,
        usesTextInput: usesTextInput,
        hasLlm: true,
        hasTts: true,
        systemPrompt: systemPrompt,
        responseSchema: responseSchema,
        voiceId: voiceId,
        speakOutput: true,
      ));

  /// Emits raw `PipelineAudioChunk` events instead of playing.
  BuiltPipeline events() => BuiltPipeline._(_PipelineSpec(
        ai: _ai,
        usesTextInput: usesTextInput,
        hasLlm: true,
        hasTts: true,
        systemPrompt: systemPrompt,
        responseSchema: responseSchema,
        voiceId: voiceId,
      ));
}

/// Terminal builder step.
class BuiltPipeline {
  BuiltPipeline._(this._spec);

  final _PipelineSpec _spec;

  /// Assembles the runnable pipeline (injects a pipeline-scoped
  /// [CancelToken]).
  RunnablePipeline build() =>
      RunnablePipeline(_spec, CancelToken());
}

class _PipelineSpec {
  const _PipelineSpec({
    required this.ai,
    required this.usesTextInput,
    required this.hasLlm,
    this.hasTts = false,
    this.systemPrompt,
    this.responseSchema,
    this.voiceId,
    this.speakOutput = false,
  });

  final LocalAI ai;
  final bool usesTextInput;
  final bool hasLlm;
  final bool hasTts;
  final String? systemPrompt;
  final JsonSchema? responseSchema;
  final String? voiceId;
  final bool speakOutput;
}

/// A runnable pipeline: one pass per [run] call.
class RunnablePipeline {
  RunnablePipeline(this._spec, this.cancelToken);

  final _PipelineSpec _spec;

  /// Pipeline-scoped cancellation; cancel to abort a running pass.
  final CancelToken cancelToken;

  /// Executes one pass and emits [PipelineEvent]s.
  Stream<PipelineEvent> run({String? textInput}) async* {
    try {
      yield const PipelineInputStarted();

      // --- Stage: input + (vad) + stt --------------------------------------
      String promptText;
      if (_spec.usesTextInput) {
        if (textInput == null || textInput.trim().isEmpty) {
          throw const InvalidStateError(
              'Pipeline run() requires textInput for text pipelines.');
        }
        promptText = textInput;
      } else {
        promptText = await _captureUtterance();
      }
      cancelToken.throwIfCancelled();
      if (promptText.trim().isEmpty) {
        yield const PipelineCompleted();
        return;
      }
      yield PipelineTranscript(text: promptText, isFinal: true);

      // --- Stage: llm -------------------------------------------------------
      if (!_spec.hasLlm || _spec.ai.config.llm == null) {
        yield const PipelineCompleted();
        return;
      }
      final chunks = await _spec.ai.generateStream(LlmRequest.prompt(
        promptText,
        systemPrompt: _spec.systemPrompt,
        responseSchema: _spec.responseSchema,
      ));
      final response = StringBuffer();
      await for (final chunk in chunks) {
        cancelToken.throwIfCancelled();
        if (chunk.textDelta.isNotEmpty) {
          response.write(chunk.textDelta);
          yield PipelineLlmDelta(chunk.textDelta);
        }
      }

      // --- Stage: tts + output ----------------------------------------------
      if (_spec.hasTts && _spec.ai.config.tts != null) {
        final audio = await _spec.ai.tts.synthesizeStream(
          response.toString(),
          voiceId: _spec.voiceId,
        );
        if (_spec.speakOutput) {
          await _spec.ai.tts.speak(response.toString(), voiceId: _spec.voiceId);
        } else {
          await for (final chunk in audio) {
            cancelToken.throwIfCancelled();
            yield PipelineAudioChunk(chunk);
          }
        }
      }

      yield const PipelineCompleted();
    } on CancelledError {
      yield const PipelineCompleted();
    } on LocalAIError catch (e) {
      yield PipelineError(e);
    } on Object catch (e) {
      yield PipelineError(
          NativeRuntimeError('pipeline stage failed', cause: e));
    }
  }

  /// Captures one VAD-segmented utterance from the microphone and
  /// transcribes it (mic → vad → stt).
  Future<String> _captureUtterance() async {
    final ai = _spec.ai;
    final vadConfig = ai.config.vad;
    final sttConfigured = ai.config.stt != null;
    if (vadConfig == null || !sttConfigured) {
      throw const InvalidStateError(
          'Audio pipelines require vad+stt in LocalAIConfig.');
    }
    final audioSource = ai.audioSource;
    if (audioSource == null) {
      throw const InvalidStateError(
          'No microphone: initialize LocalAI with enableAudio: true.');
    }
    // Ensure models are loaded, then grab the shared VAD adapter through
    // the runtime.
    await ai.models.ensureInstalled(vadConfig.modelId);
    await ai.runtime.loadModel(vadConfig.modelId);
    final vad = ai.vadAdapter;

    // Tee the broadcast mic stream: one subscription feeds the VAD, the
    // other buffers utterance frames.
    final frames = audioSource
        .start(format: AudioFormat.pcm16kMono)
        .asBroadcastStream();
    final buffer = <AudioFrame>[];
    var inSpeech = false;
    final bufferSub = frames.listen((frame) {
      if (inSpeech) buffer.add(frame);
    });

    try {
      await for (final event in vad.analyze(frames)) {
        cancelToken.throwIfCancelled();
        switch (event) {
          case VadSpeechStarted():
            inSpeech = true;
            buffer.clear();
          case VadSpeechEnded():
            inSpeech = false;
            if (buffer.isNotEmpty) {
              await audioSource.stop();
              final transcript = await ai
                  .transcribe(AudioBuffer.fromFrames(List.of(buffer)));
              return transcript.text;
            }
          case VadSpeechConfidence():
            break;
        }
      }
      return '';
    } finally {
      await bufferSub.cancel();
      await audioSource.stop();
    }
  }
}
