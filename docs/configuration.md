# Configuration

`LocalAIConfig` is the single root configuration handed to `LocalAI.initialize`; every component is optional and `null` means "not wired".

## LocalAIConfig fields

| Field | Type | Default | Description |
|---|---|---|---|
| `llm` | `LlmConfig?` | `null` | LLM component; `null` disables text generation. |
| `vad` | `VadConfig?` | `null` | Voice activity detection component. |
| `stt` | `SttConfig?` | `null` | Speech-to-text component. |
| `tts` | `TtsConfig?` | `null` | Text-to-speech component. |
| `embedding` | `EmbeddingConfig?` | `null` | Embedding component. |
| `deliveryPolicy` | `ModelDeliveryPolicy` | `ModelDeliveryPolicy.smart()` | How `bundledIfSmall` models resolve (bundle vs download). |
| `memoryPolicy` | `RuntimeMemoryPolicy` | `RuntimeMemoryPolicy()` | LRU limits, idle unload and background trim. |
| `runtimePreference` | `RuntimePreference` | `auto` | Default backend (`auto`/`cpu`/`gpu`/`npu`) for all components. |
| `remoteCatalogUrl` | `Uri?` | `null` | HTTPS endpoint for the remote model catalog. |

`copyWith` is available for deriving variants:

```dart
final config = LocalAIConfig.offlineChat().copyWith(
  remoteCatalogUrl: Uri.parse('https://models.example.com/catalog.json'),
);
```

## Component configurations

### LlmConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `modelId` | `String` | required | References a `LocalModelManifest.id` from the catalog. |
| `runtime` | `RuntimePreference` | `auto` | Preferred execution backend. |
| `maxContextTokens` | `int?` | `null` | Context window cap; `null` = model default. Adapters apply sliding-window truncation. |
| `temperature` | `double` | `0.8` | Default sampling temperature. |
| `enableGenkit` | `bool` | `false` | Wrap the LLM with the Genkit orchestration layer (requires `local_ai_genkit`). |

### SttConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `modelId` | `String` | required | Recognition model id. |
| `language` | `String?` | `null` | BCP-47 tag; `null` = auto-detect when the model supports it. |
| `enablePunctuation` | `bool` | `true` | Emit punctuated text. |

### TtsConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `modelId` | `String` | required | TTS model id. |
| `voiceId` | `String?` | `null` | Active voice; `null` = model default. |
| `speed` | `double` | `1.0` | Speaking rate multiplier. |

### VadConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `modelId` | `String` | required | VAD model id. |
| `threshold` | `double` | `0.5` | Speech probability threshold in [0, 1]. |
| `minSpeechDurationMs` | `int` | `250` | Shorter speech is discarded as noise. |
| `minSilenceDurationMs` | `int` | `500` | Silence longer than this ends an utterance. |
| `sampleRate` | `int` | `16000` | Expected input sample rate. |

### EmbeddingConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `modelId` | `String` | required | Embedding model id. |
| `dimensions` | `int?` | `null` | Output dimensions; `null` = model default. |

## Built-in presets

| Preset | Components | Delivery / runtime notes |
|---|---|---|
| `LocalAIConfig.lowMemory()` | LLM only (`gemma-3n-e2b-it-int4`, 4096 ctx) | CPU-only; `RuntimeMemoryPolicy.lowMemory()` (max 1 loaded model, 2 min idle unload). For low-RAM devices. |
| `LocalAIConfig.voiceAssistant()` | VAD (`silero-vad`) + STT (SenseVoice) + LLM (Gemma 3n) + TTS (Supertonic, `voiceId: 'supertonic-en-female-1'`) | Full voice stack; models download on first use. **Known bug:** the preset's default `voiceId` doesn't match any voice actually in the Supertonic manifest (real ids are `f1`–`f5`/`m1`–`m5`) — pass an explicit `voiceId: 'f1'` (or similar) via `copyWith`/a custom `TtsConfig` until this is fixed upstream. |
| `LocalAIConfig.offlineChat()` | LLM only | `smart(bundleBelowMB: 25)` delivery; text chat without audio. |
| `LocalAIConfig.transcription()` | VAD + STT only | No LLM/TTS; smallest footprint for speech-to-text apps. |

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig.voiceAssistant(),
  plugins: const [GemmaAdapterPlugin(), SherpaAdapterPlugin()],
);
```

## Custom presets

Compose your own by combining component configs; anything omitted is simply not wired:

```dart
const config = LocalAIConfig(
  llm: LlmConfig(
    modelId: 'gemma-3n-e2b-it-int4',
    runtime: RuntimePreference.gpu,
    maxContextTokens: 8192,
    temperature: 0.6,
  ),
  stt: SttConfig(
    modelId: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue',
    language: 'en',
  ),
  // no vad / tts / embedding
  memoryPolicy: RuntimeMemoryPolicy(
    unloadUnusedAfter: Duration(minutes: 3),
    maxLoadedModels: 2,
  ),
  runtimePreference: RuntimePreference.gpu,
);
```

Notes:

- **Voice sessions** require all four of `vad`, `stt`, `llm`, `tts` (plus audio enabled); otherwise `ai.voice.start()` throws `InvalidStateError`. Check `ai.voice.isAvailable` first.
- **`enableGenkit: true`** requires registering `GenkitAdapterPlugin` *after* the base LLM plugin — see [LLM & Genkit](llm-and-genkit.md).
- Adapter plugins must cover the `provider` of every configured model id, or resolution fails with `AdapterNotFoundError`.
