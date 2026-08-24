# Pipeline DSL

`LocalPipeline` is a typed builder chain for composing input → processing → output flows; every method returns a new stage type, so illegal orderings are compile-time errors.

## Preset pipelines

Four one-liners cover the common cases via `LocalPipeline.presets`:

| Preset | Chain | Use case |
|---|---|---|
| `textChat(ai, {systemPrompt})` | text → LLM → text | Chat UI from typed input. |
| `transcription(ai)` | mic → VAD → STT → transcript | Live transcription / dictation. |
| `voiceChat(ai, {systemPrompt, voiceId})` | mic → VAD → STT → LLM → TTS → speaker | One-shot voice Q&A. |
| `voiceCommand(ai, {required intentSchema})` | mic → VAD → STT → LLM (structured) | Intent extraction as JSON, no TTS. |

```dart
final chat = LocalPipeline.presets.textChat(ai, systemPrompt: 'Be brief.').build();
await for (final event in chat.run(textInput: 'Hello!')) {
  if (event is PipelineLlmDelta) stdout.write(event.textDelta);
}
```

## Builder chain

```dart
final pipeline = ai.pipeline()       // == LocalPipeline(ai)
    .input.microphone()              // MicStage   (or .text() for text input)
    .vad()                           // VadStage   (audio inputs only)
    .stt()                           // TextStage
    .llm(systemPrompt: 'You are helpful.')  // LlmStage
    .tts()                           // TtsStage
    .output.speaker()                // plays audio (or .events() for raw chunks)
    .build();                        // RunnablePipeline

await for (final event in pipeline.run()) {
  // PipelineEvent stream
}
```

Available transitions (enforced by types):

- `.input.microphone()` → `.vad()` → `.stt()` → text stage
- `.input.text()` → text stage directly (pass the text to `run(textInput: …)`)
- text stage → `.llm(systemPrompt:, responseSchema:)` or `.build()` (transcription end)
- LLM stage → `.tts(voiceId:)` or `.build()` (text output)
- TTS stage → `.output.speaker()` or `.output.events()`

Custom combinations are just shorter chains — e.g. speak arbitrary text (`text → LLM → TTS → speaker`), or transcribe without VAD segmentation by starting from `.input.text()`.

## Running a pipeline

`build()` produces a `RunnablePipeline` holding a pipeline-scoped `CancelToken`:

```dart
final pipeline = LocalPipeline.presets.transcription(ai).build();
final sub = pipeline.run().listen((event) { /* … */ });

// Abort mid-pass (e.g. user navigated away):
pipeline.cancelToken.cancel();
```

Each `run()` executes one pass: capture one VAD-segmented utterance (or consume `textInput`), transcribe, optionally generate, optionally synthesize, then emit `PipelineCompleted`. Text pipelines require `run(textInput: '…')` and throw `InvalidStateError` without it.

## PipelineEvent reference

| Event | Payload | Emitted by |
|---|---|---|
| `PipelineInputStarted` | — | Input stage begins. |
| `PipelineVadSpeech` | `started` | VAD speech onset/offset. |
| `PipelineTranscript` | `text`, `isFinal` | STT stage. |
| `PipelineLlmDelta` | `textDelta` | LLM streaming tokens. |
| `PipelineAudioChunk` | `chunk` (`AudioChunk`) | TTS stage when using `.output.events()`. |
| `PipelineCompleted` | — | One full pass finished (also after cancellation). |
| `PipelineError` | `error` (`LocalAIError`) | A stage failed. |

## Notes

- Audio pipelines require `vad` + `stt` in `LocalAIConfig` and `enableAudio: true`; the LLM/TTS stages are skipped gracefully when the corresponding config is absent.
- The pipeline uses the shared mic source and the runtime scheduler, so loaded models count against `maxLoadedModels` like any other usage.
- For continuous, interruptible conversation use [Voice Pipeline](voice-pipeline.md) instead — the DSL is for single-pass flows, `VoiceSession` for always-on sessions.
