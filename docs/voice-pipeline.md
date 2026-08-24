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
| `VoiceTranscriptUpdated` | `text`, `isFinal` | Incremental transcript update. |
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
| `duplex` | `DuplexMode` | `full` | `full` keeps mic+VAD active during playback; `half` mutes while speaking. |
| `systemPrompt` | `String?` | `null` | Prepended to every turn. |
| `interruptConfidenceThreshold` | `double` | `0.7` | VAD confidence needed to trigger barge-in while speaking. |
| `interruptMinSpeechMs` | `int` | `120` | Minimum speech persistence to count as barge-in. |
| `speakingVadThresholdBoost` | `double` | `0.25` | Added to the VAD threshold while TTS plays (echo mitigation). |
| `maxTurnDuration` | `Duration` | `60 s` | Hard cap per turn; exceeding it interrupts with `InterruptReason.timeout`. |

## Resource behavior

- The mic runs at `AudioFormat.pcm16kMono` (16 kHz mono) and is shared with the pipeline DSL.
- All four models stay locked in the runtime scheduler for the session; see [Runtime & Memory](runtime-memory.md).
- Errors from any stage surface as `VoiceErrorOccurred`; non-cancellation failures are wrapped in `NativeRuntimeError`.
