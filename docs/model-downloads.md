# Model Downloads

`ai.models` (`ModelHub`, backed by `ModelManagerImpl`) owns the full lifecycle of model artifacts: pre-flight checks, resumable downloads, verification and atomic installation.

## API overview

| Method | Signature | Description |
|---|---|---|
| `isInstalled` | `Future<bool> isInstalled(String modelId)` | Fully installed **and** verified. |
| `getStatus` | `Future<ModelStatus> getStatus(String modelId)` | Point-in-time status snapshot. |
| `ensureInstalled` | `Future<void> ensureInstalled(String modelId, {DownloadPolicy policy = const DownloadPolicy()})` | Idempotent: returns immediately when installed and verified; otherwise queues/starts the download. |
| `install` | `Future<void> install(String modelId, {DownloadPolicy? policy})` | Download + install even if already installed (reinstall). Concurrent installs of the same id are serialized behind one future. |
| `update` | `Future<void> update(String modelId)` | Upgrades to a newer catalog version when available (see `updatable`). |
| `remove` | `Future<void> remove(String modelId)` | Deletes installed files and download scratch data. |
| `verify` | `Future<bool> verify(String modelId)` | Full sha256 re-verification of installed files. |
| `downloadProgress` | `Stream<ModelDownloadProgress> downloadProgress(String modelId)` | Live progress (broadcast, multi-subscriber). |
| `watchStatus` | `Stream<ModelStatus> watchStatus(String modelId)` | Status changes (broadcast). |
| `registerExternalModel` | `Future<void> registerExternalModel(LocalModelManifest manifest, {required String localFilePath})` | Registers a file the app already has on disk as an installed model. No download, **no verification** — see below. |
| `installVoice` | `Future<void> installVoice(String voiceId, {required String ttsModelId, DownloadPolicy policy})` | Installs a TTS voice into `voices/<voiceId>/`. |
| `installPack` | `Future<void> installPack(String packId, {DownloadPolicy policy})` | `ensureInstalled` for every model of a `ModelPack`. |
| `refreshCatalog` | `Future<void> refreshCatalog()` | Pulls the remote catalog and merges. |
| `updatable` | `Set<String> get updatable` | Installed models with a newer catalog version available. |

## Bring your own model file

`registerExternalModel` is the entry point for a model whose files you
already have: a GGUF the user picked from the file system, an enterprise MDM
push, a build that side-loads weights. It is the only consumer of
`ModelDelivery.external`.

```dart
await ai.models.registerExternalModel(
  const LocalModelManifest(
    id: 'my-local-gguf',
    type: ModelType.llm,
    provider: ModelProviders.llamaCpp,
    delivery: ModelDelivery.external,   // required
    files: [ModelFile(name: 'my.gguf', url: '', sha256: '', sizeBytes: 0)],
  ),
  localFilePath: pickedFile.path,
);
```

What it does:

- the manifest must declare `ModelDelivery.external`, and the file must
  exist — otherwise `InvalidStateError`;
- the file is **symlinked** into `models/<type>/<id>/<name>` so a
  multi-gigabyte weight file is not duplicated. Windows, where symlinks need
  elevation or developer mode, copies instead;
- `installed.json` is written with `catalogVersion: 0` — the
  "not catalog-tracked" sentinel — and the manifest is added to the merged
  in-memory catalog and persisted, so `isInstalled`, `getStatus`, `catalog.get`
  and adapter `load()` all treat it like a catalog model;
- `remove` deletes the install directory (and the symlink) but never the
  source file.

Two behaviours differ from catalog-managed models, deliberately:

| | Catalog model | External model |
|---|---|---|
| `verify` | full streamed sha256 of every file | existence check only — there is no trusted hash to compare against |
| `update` | reinstalls when the catalog version is newer | no-op — there is no remote version |

**Nothing is verified.** A corrupt or malicious file gets no integrity check
at all; that is the trust model of `ModelDelivery.external` — the app or the
user vouched for the file. If you accept files from users, do your own
checks before calling this.

## Install state machine

```
                 ┌─────────────── failed (from any state; carries LocalAIError)
                 ▲
 notInstalled → queued → downloading ⇄ paused → verifying
                       → extracting → installing → installed → loading → ready

 installed → updating → verifying → extracting → installing → installed → ready
```

States move in one direction on the happy path; retries can step back (e.g. a sha mismatch re-downloads one file). `ModelStatus.isInstalled` is true for `installed`, `loading` and `ready`.

## Resumable downloads

Scratch state lives in `downloads/<modelId>/` as `*.part` files plus a `meta.json` (`ResumeMeta`):

```json
{
  "modelId": "gemma-3n-e2b-it-int4",
  "catalogVersion": 3,
  "etag": "…",
  "files": [{"name": "gemma-3n-E2B-it-int4.task", "received": 12345}]
}
```

- **Resume** — each file resumes from `received` via a `Range: bytes=<received>-` request; if the server ignores ranges (HTTP 200), that file restarts from zero. Appends flush every 4 MB and `meta.json` updates are atomic (`meta.json.tmp` → rename).
- **Retry** — network errors retry with exponential backoff (1 s / 2 s / 4 s, capped at 30 s, up to `DownloadPolicy.maxRetries`, default 5); HTTP 4xx fails immediately.
- **Crash recovery** — on `initialize()`, the installer scans `models/` (not `downloads/`) and deletes any model directory that's missing `installed.json` or has the marker but no payload files; `downloads/` scratch state is left untouched so an interrupted download resumes normally via its `meta.json`.

## Verification & atomic install

1. **Pre-flight**: disk check against `sizeBytes × 1.2` headroom (throws `InsufficientDiskError` with `requiredMB`/`freeMB`) and network policy check.
2. **Streamed sha256**: once a file finishes downloading, its digest is computed in a chunked, constant-memory pass over the completed `.part` file (not concurrently with the download itself); any mismatch deletes and re-downloads that file (at most 2 full rounds, then `ModelCorruptedError`).
3. **Atomic install**: once all files verify, `downloads/<modelId>` is `rename`d into `models/<type>/<modelId>/` — guaranteed atomic because both live under the same root partition. Finally `installed.json` (with `catalogVersion`, `installedAt`) is written as the completion marker. A model only counts as installed once its directory has both the marker *and* non-empty payload files — `getStatus`/`isInstalled` check both.

## Progress streams

```dart
ai.models.downloadProgress(Models.gemma3nE2b.id).listen((p) {
  // p.state, p.receivedBytes, p.totalBytes, p.bytesPerSecond,
  // p.eta, p.currentFile, p.fraction (0..1)
});
ai.models.watchStatus(Models.gemma3nE2b.id).listen((s) {
  // s.state, s.installedCatalogVersion, s.progress, s.error
});
```

Both streams are broadcast: multiple widgets may subscribe independently.

## Wi-Fi only & DownloadPolicy

```dart
await ai.models.ensureInstalled(
  Models.gemma3nE2b.id,
  policy: const DownloadPolicy(
    wifiOnly: true,   // default; on cellular the download stays queued
    maxRetries: 5,    // exponential backoff attempts
    verifySha256: true,
  ),
);
```

With `wifiOnly: true`, starting a download on a metered connection leaves it in `queued`; the manager subscribes to `NetworkPolicy.onStatusChanged` and resumes automatically when Wi-Fi returns. Set `wifiOnly: false` only when the user has explicitly consented to cellular data use.

## Voices and packs

```dart
// Individual voice (files land in voices/<voiceId>/). Supertonic voice
// ids are 'f1'-'f5' (female) / 'm1'-'m5' (male).
await ai.tts.installVoice('m1');

// Whole curated bundle.
await ai.models.installPack('voice-assistant-pack');
```

Install packs through `ai.models`, not `ai.catalog` — `ModelCatalogService.installPack` (reachable via `ai.catalog`) always throws `UnsupportedError` and points back to `ModelHub.installPack`.

## Compatibility checks

Before offering a model for download, check it against the probed device:

```dart
final manifest = await ai.catalog.get(Models.gemma3nE2b.id);
final report = await ai.runtime.checkCompatibility(manifest);
if (!report.isCompatible) {
  print(report.summary); // e.g. memory or platform mismatch reasons
}
```

`CompatibilityReport` carries `reasons`, `availableMemoryMB` and `requiredMemoryMB`; `ai.runtime.deviceCapabilities()` returns the raw `DeviceCapabilities` snapshot (RAM, free disk, platform, detected accelerators).
