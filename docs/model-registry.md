# Model Registry & Catalog

Every model the kit can run is described declaratively by a `LocalModelManifest`; manifests come from the built-in catalog (`Models`), an optional remote catalog, or app-supplied entries, and are merged by `catalogVersion`.

## LocalModelManifest fields

| Field | Type | Default | Description |
|---|---|---|---|
| `id` | `String` | required | Unique id, e.g. `gemma-3n-e2b-it-int4`. |
| `type` | `ModelType` | required | `llm` / `stt` / `vad` / `tts` / `embedding`. |
| `provider` | `String` | required | Adapter routing key (see `AdapterRegistry`), e.g. `google-gemma`, `sherpa-community`. |
| `files` | `List<ModelFile>` | required | Downloadable files: `name`, `url`, `sha256`, `sizeBytes`, optional `relativePath`. |
| `delivery` | `ModelDelivery` | required | How files reach the device (see below). |
| `languages` | `List<String>` | `[]` | BCP-47 language tags. |
| `platforms` | `List<String>` | `['android', 'ios']` | Supported platforms. |
| `minMemoryMB` | `int` | `0` | Minimum free RAM required to load. |
| `quantization` | `String?` | `null` | `int4` / `int8` / `fp16` (informational). |
| `contextLength` | `int?` | `null` | Max context tokens (LLM only). |
| `capabilities` | `Set<ModelCapability>` | `{}` | `chat`, `functionCalling`, `vision`, `streaming`, `asrStreaming`, `asrOffline`, `vadStreaming`, `ttsStreaming`, `multilingual`, `embedding`. |
| `license` | `String` | `'unknown'` | SPDX id or human readable license. |
| `voices` | `List<LocalVoice>?` | `null` | TTS only: independently installable voices, each with its own files/sha256. |
| `catalogVersion` | `int` | `1` | Monotonic revision used by the merge strategy (higher wins). |
| `displayName` / `description` | `String?` | `null` | UI metadata. |

Computed helpers: `totalSizeBytes`, `totalSizeMB`. Serialization: `toJson()` / `LocalModelManifest.fromJson()`.

## Built-in catalog (`Models`)

`Models` is the always-available offline fallback. Well-known provider keys live in `ModelProviders` (`googleGemma`, `sherpaCommunity`).

| Constant | id | Type | Delivery | Notes |
|---|---|---|---|---|
| `Models.qwen25_05b` | `qwen-2.5-0.5b-instruct` | LLM | `download` | Qwen 2.5 0.5B Instruct (int8), 4k context, ~547 MB — fastest/lightest chat model. |
| `Models.qwen35_08b` | `qwen-3.5-0.8b-instruct` | LLM | `download` | Qwen 3.5 0.8B Instruct (int8 LiteRT-LM), 4k context, ~963 MB. |
| `Models.qwen35_2b` | `qwen-3.5-2b-instruct` | LLM | `download` | Qwen 3.5 2B Instruct (int8 LiteRT-LM), 4k context, ~2.1 GB. |
| `Models.qwen35_4b` | `qwen-3.5-4b-instruct` | LLM | `download` | Qwen 3.5 4B Instruct (int8 LiteRT-LM), 4k context, ~4.4 GB. |
| `Models.smollm2` | `smollm2-360m-instruct` | LLM | `download` | SmolLM2 360M Instruct (LiteRT-LM int8), 2k context, ~374 MB. |
| `Models.deepseekR1` | `deepseek-r1-1.5b-int4` | LLM | `download` | DeepSeek R1 Distill Qwen 1.5B (LiteRT-LM), ~1.86 GB. |
| `Models.gemma4E2b` | `gemma-4-e2b-it` | LLM | `download` | Gemma 4 E2B IT (LiteRT-LM), 8k context, ~2.59 GB. |
| `Models.gemma4E4b` | `gemma-4-e4b-it` | LLM | `download` | Gemma 4 E4B IT (LiteRT-LM), 8k context, ~3.66 GB. |
| `Models.gemma3nE2b` | `gemma-3n-e2b-it-int4` | LLM | `download` | Gemma 3n E2B IT (LiteRT-LM), 32k context, ~2.59 GB. |
| `Models.sileroVad` | `silero-vad` | VAD | `bundledIfSmall` | Silero VAD, ~0.6 MB — bundled under the smart policy. |
| `Models.senseVoiceSmall` | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue` | STT | `download` | SenseVoice Small multilingual ASR (zh/en/ja/ko/yue), ~234 MB + tokens. |
| `Models.zipformerSmall` | `sherpa-onnx-streaming-zipformer-en-20m` | STT | `download` | Fast streaming English Zipformer ASR, ~70 MB. |
| `Models.whisperBase` | `sherpa-onnx-whisper-base.en` | STT | `download` | Whisper Base English ASR (OpenAI), ~75 MB. |
| `Models.whisperTiny` | `sherpa-onnx-whisper-tiny.en` | STT | `download` | Whisper Tiny English ASR (OpenAI), ~40 MB. |
| `Models.moonshineTiny` | `sherpa-onnx-moonshine-tiny-en` | STT | `download` | Moonshine Tiny English ASR, sub-100ms latency, ~30 MB. |
| `Models.moonshineTinyV2En` / `moonshineTinyV2Ja` / `moonshineTinyV2Ko` | `sherpa-onnx-moonshine-tiny-{en,ja,ko}-quantized-2026-02-27` | STT | `download` | Moonshine v2 Tiny ASR for English, Japanese, and Korean, ~45 MB each. |
| `Models.moonshineBaseV2Ar` / `moonshineBaseV2En` / `moonshineBaseV2Es` / `moonshineBaseV2Ja` / `moonshineBaseV2Uk` / `moonshineBaseV2Vi` / `moonshineBaseV2Zh` | `sherpa-onnx-moonshine-base-{ar,en,es,ja,uk,vi,zh}-quantized-2026-02-27` | STT | `download` | Moonshine v2 Base ASR for Arabic, English, Spanish, Japanese, Ukrainian, Vietnamese, and Chinese, ~65–140 MB each. |
| `Models.dolphinBase` | `sherpa-onnx-dolphin-base-ctc-multi-lang-2025-04-02` | STT | `download` | Multilingual Dolphin Base CTC ASR, 40 languages plus Chinese dialect regions, ~318 MB. |
| `Models.dolphinBaseInt8` | `sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02` | STT | `download` | Quantized multilingual Dolphin Base CTC ASR, ~104 MB. |
| `Models.supertonic` | `supertonic-tts` | TTS | `download` | Supertonic 3 (Supertone Inc.), 31+ languages, 10 voice styles (`F1`–`F5`, `M1`–`M5`), 44.1 kHz neural flow matching (~398 MB). |
| `Models.kokoroTts` | `kokoro-en-tts` | TTS | `download` | Kokoro TTS v0.19 fast streaming text-to-speech (~319 MB). |
| `Models.vitsPiper` | `vits-piper-en-lessac` | TTS | `download` | Piper VITS Lessac offline voice (~65 MB). |

```dart
final all = Models.all;                     // List<LocalModelManifest>
final qwen = Models.byId('qwen-3.5-0.8b-instruct'); // LocalModelManifest?
final supertonic = Models.byId('supertonic-tts');   // LocalModelManifest?
```

## ModelDelivery strategies

| Value | Behavior |
|---|---|
| `bundled` | Files ship inside the app bundle (only viable for tiny models). |
| `download` | Files are downloaded on first use. |
| `bundledIfSmall` | Resolved at build/packaging time by the app-wide `ModelDeliveryPolicy`. |
| `external` | App or user supplies the files (sideload / enterprise MDM / file picker). Registered with `ai.models.registerExternalModel` — see [Model Downloads](model-downloads.md#bring-your-own-model-file). |

### The smart policy

```dart
class ModelDeliveryPolicy {
  const ModelDeliveryPolicy.smart({this.bundleBelowMB = 25});
  ModelDelivery resolve(ModelDelivery declared, int totalSizeBytes);
}
```

`bundledIfSmall` manifests with total size below `bundleBelowMB` (default **25 MB**) are bundled into the app; everything else downloads on demand. The `verify:bundle-policy` melos task enforces the threshold at build time, so an oversized bundled asset fails CI instead of bloating the release binary.

## Remote catalog

Set `LocalAIConfig.remoteCatalogUrl` to an HTTPS endpoint returning this JSON shape:

```json
{
  "catalogVersion": 3,
  "updatedAt": "2025-01-15T10:00:00Z",
  "models": [
    {
      "id": "gemma-3n-e2b-it-int4",
      "type": "llm",
      "provider": "google-gemma",
      "delivery": "download",
      "catalogVersion": 3,
      "files": [
        {"name": "gemma-3n-E2B-it-int4.task", "url": "https://…", "sha256": "…", "sizeBytes": 2900000000}
      ]
    }
  ]
}
```

`RemoteCatalogLoader` fetches it with a 15 s timeout, caches the raw JSON to `manifests/catalog.remote.json` (atomic tmp+rename write), and returns `null` on any network/parse failure so callers can fall back.

### Merge rules (by model id)

1. Remote `catalogVersion` > local → the remote entry **overrides** the built-in one.
2. Remote-only ids are **appended**.
3. Remote **never deletes** entries — installed models always keep their manifest.
4. If the remote changes `files[].sha256` of an *installed* model with a higher version, the model is flagged **updatable** (`ai.models.updatable`) — it is *not* auto-reinstalled; call `ai.models.update(modelId)`.

The merged result is persisted to `manifests/catalog.merged.json`. Fallback order on fetch failure: cached remote catalog → built-in catalog. Trigger a merge manually with `ai.models.refreshCatalog()` (or `ai.catalog.refresh()`); it also runs once during `LocalAI.initialize`.

## ModelPack

A `ModelPack` is a curated bundle installed in one call:

```dart
class ModelPack {
  final String id;
  final String name;
  final String description;
  final List<String> modelIds;
}
```

Built-in packs (from `ai.catalog.packs`):

| Pack id | Contents |
|---|---|
| `voice-assistant-pack` | Silero VAD + SenseVoice STT + Gemma 3n + Supertonic TTS. |
| `transcription-pack` | Silero VAD + SenseVoice STT. |

```dart
for (final pack in ai.catalog.packs) {
  print('${pack.name}: ${pack.description}');
}
await ai.models.installPack('voice-assistant-pack');
```

See [Model Downloads](model-downloads.md) for the install pipeline behind `installPack` and `ensureInstalled`.
