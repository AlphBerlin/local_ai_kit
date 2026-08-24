# Storage Layout

All model artifacts, catalogs and caches live under one app-support root managed by `LocalStoragePaths` (default: `FlutterStoragePaths`).

## Directory tree

```
<app-support>/local_ai/
├── models/
│   ├── llm/<modelId>/          e.g. models/llm/gemma-3n-e2b-it-int4/
│   ├── stt/<modelId>/          each installed model dir contains
│   ├── vad/<modelId>/          installed.json  (catalogVersion, installedAt)
│   ├── tts/<modelId>/
│   └── embedding/<modelId>/
├── voices/<voiceId>/           TTS voices, installed independently of models
├── manifests/
│   ├── catalog.remote.json     last fetched remote catalog (cache)
│   └── catalog.merged.json     built-in ⊕ remote merge result
├── downloads/<modelId>/        in-progress downloads: *.part + meta.json
└── cache/                      KV cache, temp audio — purgeable by the OS
```

## Path rules

- **Single root, same partition**: `downloads/` and `models/` must live under the same root so the final install step (`downloads/<id>` → `models/<type>/<id>`) is an atomic same-partition rename.
- **Marker file**: a model directory counts as installed only when `installed.json` exists; anything else is treated as a partial install.
- **Voices are separate**: voice files live in `voices/<voiceId>/`, not inside the TTS model directory, so voices can be added/removed without touching the base model.
- **`cache/` is expendable**: never store anything there that cannot be recomputed; the OS may purge it under storage pressure.

## LocalStoragePaths API

| Member | Resolves to |
|---|---|
| `rootDir` | `<app-support>/local_ai` |
| `modelsDir` | `rootDir/models` |
| `modelDir(type, modelId)` | `rootDir/models/<type>/<modelId>` |
| `downloadsDir` | `rootDir/downloads` |
| `downloadDir(modelId)` | `rootDir/downloads/<modelId>` |
| `voicesDir` | `rootDir/voices` |
| `voiceDir(voiceId)` | `rootDir/voices/<voiceId>` |
| `manifestsDir` | `rootDir/manifests` |
| `cacheDir` | `rootDir/cache` |
| `ensureInitialized()` | Creates the full tree (called during `LocalAI.initialize`). |

The default implementation resolves via `path_provider`:

```dart
final paths = await FlutterStoragePaths.resolve();       // subdir: 'local_ai'
final testPaths = FlutterStoragePaths.at(Directory.systemTemp); // testing hook
```

Pass a custom `paths` to `LocalAI.initialize(paths: …)` to relocate the root (e.g. per-profile storage in tests).

## Cleanup strategies

- **Crash recovery** — at startup, `ModelInstaller.recoverFromCrash()` resumes interrupted downloads from `downloads/<id>/meta.json` and deletes half-installed model directories lacking `installed.json`.
- **Explicit removal** — `ai.models.remove(modelId)` deletes both the installed directory and any download scratch data.
- **Cache purge** — `cache/` holds KV cache and temporary audio; it is safe to clear at any time and is excluded from integrity verification.
- **Catalog files** — `catalog.remote.json` and `catalog.merged.json` are rewritten atomically (tmp file + rename) on every successful refresh.
