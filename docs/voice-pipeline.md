# Voice Pipeline

`ai.voice` runs a full-duplex voice session — Mic → VAD → STT → LLM → TTS → Speaker — over a single broadcast event stream, with barge-in support.

## Starting a session

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig.voiceAssistant(),
  plugins: const [GemmaAdapterPlugin(), SherpaAdapterPlugin()],
);

if (!ai.voice.isAvailable) {
  throw StateError('Voice requires vad + stt + llm + tts config and audio.');
}

final session = await ai.voice.start(
  sessionConfig: const VoiceSessionConfig(
    systemPrompt: 'You are a helpful voice assistant. Keep answers short.',
    bargeIn: true,
  ),
);

session.events.listen((event) { /* drive your UI */ });

// Later — stops the mic, cancels any in-flight turn, unlocks models:
await session.stop();
```

`start()` loads all four components and **locks** them against LRU eviction for the session lifetime (unlocked again by `stop()`). It throws `InvalidStateError` when the config or audio stack is incomplete.

## VoiceEvent reference

All events are emitted on `session.events` (broadcast):

| Event | Payload | Meaning |
|---|---|---|
| `VoiceListening` | — | Session is listening to the microphone. |
| `VoiceSpeechStarted` | — | VAD detected speech onset. |
| `VoiceSpeechEnded` | — | VAD detected speech offset; utterance goes to STT. |
| `VoiceTranscriptUpdated` | `text`, `isFinal` | Incremental transcript update. Final text is passed through `collapseRepeatedWords` (`local_ai_core`) to collapse immediate word/phrase repeats that are a common STT decoding artifact. |
| `VoiceThinking` | — | LLM is generating (no tokens yet). |
| `VoiceResponseStarted` | — | First LLM tokens arrived. |
| `VoiceResponseDelta` | `textDelta` | Incremental assistant text. |
| `VoiceSpeaking` | `text?` | TTS is speaking (sentence when known). |
| `VoiceFinished` | — | Full turn completed; session returns to listening. |
| `VoiceInterrupted` | `reason` | Turn interrupted: `InterruptReason.bargeIn` / `.cancelled` / `.timeout`. |
| `VoiceErrorOccurred` | `error` (`LocalAIError`) | A stage failed; the session may recover to listening. |

```dart
session.events.listen((event) {
  switch (event) {
    case VoiceListening():
      setState(() => status = 'Listening…');
    case VoiceTranscriptUpdated(:final text, :final isFinal):
      setState(() => userText = text);
    case VoiceResponseDelta(:final textDelta):
      appendAssistant(textDelta);
    case VoiceInterrupted(:final reason):
      setState(() => status = 'Interrupted ($reason)');
    case VoiceErrorOccurred(:final error):
      showError(error.message);
    default:
      break;
  }
});
```

## Per-sentence TTS pipelining

As the LLM streams a response, `VoiceSession` extracts complete sentences
(text ending in `.`/`!`/`?`) from the running buffer and queues each one for
TTS as soon as it's detected, instead of waiting for the full response
before synthesis starts. This cuts time-to-first-audio: playback of the
first sentence can begin while the LLM is still generating the rest.

- `VoiceSpeaking(text: sentence)` fires once per sentence, not once per
  turn — expect several `VoiceSpeaking` events in a single response.
- Any leftover text once the stream ends (no trailing punctuation) is
  flushed as a final "sentence".
- Barge-in during this multi-sentence playback cancels the whole turn (the
  in-flight sentence's playback and any still-queued ones) exactly like the
  single-sentence case.

## Barge-in

While TTS is playing, the VAD keeps analyzing the mic. An interruption triggers when speech confidence exceeds `interruptConfidenceThreshold + speakingVadThresholdBoost` **and** speech persists for at least `interruptMinSpeechMs` (default 120 ms — filters clicks and echo blips). On trigger:

1. `audioOutput.stop()` truncates playback immediately;
2. the in-flight LLM generation and TTS synthesis are cancelled via the turn's `CancelToken`;
3. `VoiceInterrupted(reason: InterruptReason.bargeIn)` is emitted and the session returns to listening — the interrupting speech becomes the next utterance (a rolling pre-buffer keeps the onset from being clipped).

Without acoustic echo cancellation, speaker output can look like speech to the VAD; the raised threshold plus persistence check mitigate this, but **headphones are recommended** for reliable barge-in.

## VoiceSessionConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `bargeIn` | `bool` | `true` | Allow the user to interrupt playback by speaking. |
| `duplex` | `DuplexMode` | `full` | Declared for future half/full-duplex switching, but not currently read anywhere in `VoiceSession` — mic suppression during playback is presently unconditional regardless of this setting. Treat `half` as a no-op for now. |
| `systemPrompt` | `String?` | `null` | Prepended to every turn. |
| `interruptConfidenceThreshold` | `double` | `0.7` | VAD confidence needed to trigger barge-in while speaking. |
| `interruptMinSpeechMs` | `int` | `120` | Minimum speech persistence to count as barge-in. |
| `speakingVadThresholdBoost` | `double` | `0.25` | Added to the VAD threshold while TTS plays (echo mitigation). |
| `maxTurnDuration` | `Duration` | `60 s` | Hard cap per turn; exceeding it interrupts with `InterruptReason.timeout`. |

## Audio formats and resource behavior

- **Microphone & VAD/STT Capture**: Operates at `AudioFormat.pcm16kMono` (16 kHz mono float32) for optimal Silero VAD and Zipformer/SenseVoice feature extraction.
- **Speech Synthesis (TTS) Output**: Streams at whatever mono float32 `AudioFormat` matches the engine's reported sample rate — `pcm44kMonoFloat` (44.1 kHz) for Supertonic 3, `pcm24kMonoFloat` (24 kHz) for Kokoro's native rate, with `pcm44kMonoFloat` as the fallback for any other rate — never resampled, so no pitch shift or downsampling loss either way.
- **Multilingual Voice Routing**: `SpeakRequest` and `VoiceSession` support explicit BCP-47 `language` (e.g. `'ja'`, `'ko'`, `'en'`, `'zh'`) and `voiceId` parameters (e.g. `'f1'` through `'f5'`, `'m1'` through `'m5'`).
- All four models stay locked in the runtime scheduler for the session; see [Runtime & Memory](runtime-memory.md).
- Errors from any stage surface as `VoiceErrorOccurred`; non-cancellation failures are wrapped in `NativeRuntimeError`.
