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
| `Models.gemma3nE2b` | `gemma-3n-e2b-it-int4` | LLM | `download` | Gemma 3n E2B IT, int4, 32k context, ~2.9 GB, min 3 GB RAM. |
| `Models.sileroVad` | `silero-vad` | VAD | `bundledIfSmall` | Silero VAD, ~2.3 MB — bundled under the smart policy. |
| `Models.senseVoiceSmall` | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue` | STT | `download` | SenseVoice Small streaming ASR (zh/en/ja/ko/yue), ~234 MB + tokens. |
| `Models.supertonic` | `supertonic-tts` | TTS | `download` | Supertonic streaming TTS, ~90 MB base + two voices (`supertonic-en-female-1`, `supertonic-en-male-1`, ~8 MB each). |

```dart
final all = Models.all;                 // List<LocalModelManifest>
final m = Models.byId('silero-vad');    // LocalModelManifest? (null-safe lookup)
```

## ModelDelivery strategies

| Value | Behavior |
|---|---|
| `bundled` | Files ship inside the app bundle (only viable for tiny models). |
| `download` | Files are downloaded on first use. |
| `bundledIfSmall` | Resolved at build/packaging time by the app-wide `ModelDeliveryPolicy`. |
| `external` | User supplies the files (sideload / enterprise MDM). |

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
