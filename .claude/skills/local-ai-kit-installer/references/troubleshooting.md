# Troubleshooting

Symptom to cause, for the integration guide you write and for debugging one
that already exists. Verify the current behaviour in the source before
quoting any of this as fact — file paths are given so you can.

## Errors from the kit

Every failure crossing a package boundary is a `LocalAIError`
(`packages/local_ai_core/lib/src/errors/local_ai_error.dart`).

### `AdapterNotFoundError`

"No adapter registered for provider X and capability Y."

The config names a model whose manifest `provider` has no registered factory.
Almost always a missing entry in `LocalAI.initialize(plugins: [...])`.

Note the timing: this throws at the **first use**, not at `initialize`, so it
can surface minutes in and after a download. When wiring a new capability,
call it once during startup to fail fast, or check
`ai.adapters` after initialize.

Match the provider to the plugin using `docs/adapters.md`. A `.gguf` model
routes to `LlamaCppAdapterPlugin`; a `.task` / `.litertlm` / `.bin` model to
`GemmaAdapterPlugin`; VAD/STT/TTS to `SherpaAdapterPlugin`.

### `IncompatibleDeviceError`

The compatibility checker found a blocking issue before downloading or
loading. `error.report` carries the detail:

- `report.reasons` — the blocking messages
- `report.blockers` / `report.warnings` — typed `CompatibilityIssue`s
- each issue's `check` says which: `platform`, `totalMemory`,
  `availableMemory`, `disk`, `accelerator`, `contextWindow`, `unknown`

The three common causes:

| `check` | Meaning | What to do |
|---|---|---|
| `platform` | The manifest does not list this OS | On Linux/Windows this is usually accurate — most catalog models are mobile/macOS only. Use a GGUF model via `local_ai_llama_cpp`, or `CompatibilityEnforcement.warn` if the user knows better |
| `disk` | Not enough space for the download plus install headroom (size × 1.2) | Free space, or pick a smaller model |
| `totalMemory` | The device has less RAM than `minMemoryMB` | Pick a smaller or more heavily quantized model |

`CompatibilityEnforcement.off` skips the probe entirely. Reach for it only
when the user has heard what the check found and chosen to override it —
never as a way to silence an error you have not explained.

### `InsufficientDiskError`

From `DownloadManager._preflight`, which needs `size × 1.2`. It runs at the
top of `download()` — before the scratch directory is created and before any
file is fetched — so it is a second pre-flight, not a mid-transfer failure.

Distinct from the `disk` compatibility issue only in *who* checks: the
compatibility gate runs first, against the probed device; this one runs
against the injected `FreeDiskProbe`. Seeing it usually means the gate was
disabled (`CompatibilityEnforcement.off`/`warn`), no device probe was wired,
or free space fell between the two checks.

### `ModelCorruptedError`

A file failed sha256 twice. The downloader already deleted and re-fetched it
once. Usually a truncating proxy or a stale catalog hash — check whether the
manifest's `sha256` matches what the URL actually serves.

### `NetworkPolicyViolationError`

`DownloadPolicy.wifiOnly` defaults to **`true`**. On cellular the download
does not start. This is the most common "the download does nothing" report.

The inverse also exists, and is worth knowing before you rely on
`wifiOnly` to protect a data plan: `FlutterNetworkPolicy._map` collapses
every `ConnectivityResult` it does not recognise onto `NetworkStatus.unknown`
— which on Android includes `vpn`, and on iOS includes `other`, the result
iOS reports whenever a VPN is active. `canDownload` then **fails open** on
`unknown` without consulting `wifiOnly`, so a user on cellular behind a VPN
can start a multi-gigabyte download the policy was meant to defer. Treat
`wifiOnly` as best-effort until that is fixed, and check `currentStatus()`
yourself if the guarantee matters.

```dart
await ai.models.ensureInstalled(
  modelId,
  policy: const DownloadPolicy(wifiOnly: false),
);
```

Surface it in the UI as a choice ("download over mobile data?") rather than
flipping it silently — the default exists to protect the user's data plan.

### `InvalidStateError` "X is not configured"

The facade was used for a capability whose `LocalAIConfig` field is `null`.
`LocalAIConfig(llm: ...)` gates `ai.generate`, `stt:` gates `ai.transcribe`,
and so on.

### `InvalidStateError` "loaded as … which is not a …"

The manifest's `provider` resolves to an adapter of the wrong capability —
e.g. a provider registered with `registerLlm` used by a model whose `type` is
`stt`. Fix the manifest's provider or the registration, not the call site.

### `StructuredOutputError`

`generateStructured` could not get schema-valid JSON after its retries. With
`local_ai_llama_cpp` this should be near-impossible — it constrains
generation with a GBNF grammar — so hitting it there points at the schema
conversion (`json_schema_to_gbnf.dart`) rather than at the model.

## Not an error, but wrong

### The app freezes with no feedback

Two separate multi-second waits need two separate UIs:

- downloading — `ai.models.downloadProgress(id)`
- loading — `ai.runtime.loadProgress(id)`

An app that only builds the first still looks frozen while the model loads.

### The progress bar sits at 0% then jumps to 100%

`ModelLoadProgress.fraction` is `null` on a model's very first load, because
nothing is known yet about how long it takes on this device. Render an
indeterminate indicator when `fraction == null` and a determinate one
otherwise; from the second load on it is populated from the previous
measurement.

### A model reloads constantly

`RuntimeMemoryPolicy.maxLoadedModels` defaults to `2`. A voice assistant
wants VAD + STT + LLM + TTS, so something is always being evicted.

Check `ai.runtime.cacheStats`: a high `missRate` together with many
`evictions` over a small set of ids is thrashing.

```dart
ai.pinModel(llmModelId);                       // never evicted
// or
LocalAIConfig(memoryPolicy: RuntimeMemoryPolicy(maxLoadedModels: 4))
```

Pinning costs RAM permanently — weigh it against the reload it avoids, which
`cacheStats.lastLoadDurations` prices for you.

### The model unloads while the app is in the background

`RuntimeMemoryPolicy.trimOnBackground` defaults to `true`, and the idle sweep
unloads anything untouched for `unloadUnusedAfter` (default 5 minutes). Both
are deliberate; pin the model or change the policy if the reload is worse
than the memory.

### STT or TTS does nothing on a phone

Per `AGENTS.md`: `local_ai_sherpa`'s STT and TTS shell out to a `uv run
python3` subprocess and are desktop-only, and its VAD is a pure-Dart
RMS-energy heuristic rather than the Silero model. Re-read `AGENTS.md` before
repeating this — it is the part of the repo most likely to have changed — but
do not promise production mobile STT while it still says so.

### llama.cpp throws at load after a clean build

The native library is not bundled. `llama_cpp_dart` is bindings-only. See
`packages/local_ai_llama_cpp/native/README.md` and the note in
`references/platform-setup.md`.

## Diagnostics worth adding to an integration

```dart
ai.runtime.events.listen((event) {
  switch (event) {
    case RuntimeModelLoadProgress(:final progress):
      log('${progress.modelId}: ${progress.phase.name} '
          '(${progress.elapsed.inMilliseconds}ms)');
    case RuntimeBackendFallback(:final modelId, :final reason):
      log('$modelId fell back to CPU: $reason');
    case RuntimeCompatibilityChecked(:final modelId, :final report):
      if (report.hasWarnings) log('$modelId: ${report.summary}');
    case RuntimeModelUnloaded(:final modelId, :final reason):
      log('$modelId unloaded ($reason)');
    default:
      break;
  }
});
```

`RuntimeBackendFallback` is the quiet one: a GPU/NPU load that failed and
silently retried on CPU explains a model that works but is inexplicably slow.
