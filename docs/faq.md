# FAQ

Answers to the questions that come up most often when integrating LocalAI Kit.

## Does the kit work fully offline?

Yes — that is the default. The built-in catalog (`Models`) is always available without network, inference runs entirely on-device, and `ModelDelivery.bundled` / `bundledIfSmall` models ship inside the app. Network is only needed to download `download`-delivery models and to refresh the optional remote catalog. Once a model is installed and verified, no connection is required.

## How do model updates work?

When the remote catalog carries a higher `catalogVersion` with changed file hashes for an installed model, the model is flagged in `ai.models.updatable` and its status moves to `updating`. Nothing is overwritten automatically — call `ai.models.update(modelId)` when it suits your UX. The remote catalog can never delete entries, so installed models always keep a valid manifest. See [Model Registry & Catalog](model-registry.md).

## What happens when the device runs out of RAM?

Three layers of defense:

1. **Pre-check** — `ai.models.checkCompatibility(modelId)` compares the model's RAM and disk requirements against the device before you even offer a download, and `install` / `ensureInstalled` / `loadModel` enforce the same check themselves (throwing `IncompatibleDeviceError`) unless `LocalAIConfig.compatibilityEnforcement` says otherwise. The probe is `FlutterDeviceProbe`, wired by default: it reads mobile metrics through `device_info_plus` and desktop metrics through native OS commands. A metric it cannot read is reported as `0` and produces an *unknown* warning naming the skipped check — never a fabricated capacity, and never a silent pass. The same holds when the probe fails outright: the check runs against `DeviceCapabilities.unknown()`, so every affected check is reported as skipped rather than quietly passing, and an unprobed device is not mistaken for a CPU-only one. Inject a stricter `DeviceMetricsSource` when a reliable platform-specific value is required.
2. **LRU policy** — `RuntimeMemoryPolicy.maxLoadedModels` caps simultaneously loaded models; the least-recently-used unlocked model is evicted first, idle models are swept after `unloadUnusedAfter`, and backgrounding trims everything unlocked.
3. **Fallback** — if a `gpu`/`npu` load fails, the scheduler retries on `cpu` and reports `RuntimeBackendFallback`.

For constrained devices start from `LocalAIConfig.lowMemory()` (CPU-only, one loaded model max, 2-minute idle unload).

## Can downloads run in the background / over cellular?

Downloads are resilient to app lifecycle: progress is persisted in `downloads/<id>/meta.json`, so a killed app resumes with HTTP `Range` requests on next launch. By default `DownloadPolicy.wifiOnly` is `true` — on cellular the download waits in `queued` and resumes automatically when Wi-Fi returns. Pass `const DownloadPolicy(wifiOnly: false)` only with explicit user consent.

## Which platforms are supported?

| Package | Android | iOS | macOS | Other |
|---|---|---|---|---|
| `local_ai_core` | ✅ | ✅ | ✅ | Any pure-Dart target |
| `local_ai_flutter` (platform layer) | ✅ | ✅ | ✅ | — |
| Gemma LLM adapter | ✅ | ✅ | — | per flutter_gemma |
| Sherpa VAD/STT/TTS adapters | ⚠️ | ⚠️ | ✅ | see caveat below |

Each manifest also declares its own `platforms` list, and `checkCompatibility` enforces it at runtime. Most catalog manifests list `['android', 'ios', 'macos']`, so on Linux and Windows they are genuinely reported incompatible — the GGUF models served by `local_ai_llama_cpp` are the ones that declare desktop support. When developing on Linux, `LocalAIConfig(compatibilityEnforcement: CompatibilityEnforcement.warn)` is the documented escape hatch.

**Sherpa adapter caveat:** the manifests list Android/iOS as supported platforms, but the current `local_ai_sherpa` implementation does not use the `sherpa_onnx` Dart package at all — STT/TTS shell out to a `uv run python3` subprocess (desktop-only; Android/iOS sandboxing doesn't allow spawning arbitrary subprocesses) and VAD is a pure-Dart RMS-energy heuristic, not Silero. Treat Android/iOS support for these three adapters as unverified until they're re-implemented against real FFI bindings — see [Adapters → Built-in adapter implementations](adapters.md) for details.

## Why do I have to register adapter plugins explicitly?

Because registration is what keeps unused native runtimes out of your binary. `local_ai_kit` has no dependency on flutter_gemma, sherpa_onnx or Genkit — if you don't list `SherpaAdapterPlugin()`, the onnxruntime native libraries are never linked. The cost is one line in `LocalAI.initialize`; the benefit is a smaller app and full tree-shaking.

## How reliable is structured output on small models?

Small quantized models sometimes ignore schemas. The kit mitigates this with schema injection (grammar/constrained decoding when the runtime supports it, prompt injection otherwise) plus an automatic retry loop that feeds the parse error back into the prompt; after `maxRetries` (default 2) it throws `StructuredOutputError`. Keep schemas shallow and prefer enum-constrained strings where possible.

## Barge-in triggers by itself — the assistant interrupts itself?

Without acoustic echo cancellation, speaker output can leak into the mic and look like speech to the VAD. The pipeline already raises the VAD threshold during playback (`speakingVadThresholdBoost`, default +0.25) and requires 120 ms of persistent speech. If false triggers persist: raise `interruptConfidenceThreshold` (default 0.7), use `DuplexMode.half` to mute the mic while speaking, or recommend headphones.

## How do I test without a device?

`local_ai_core` is pure Dart and ships in-memory fakes (`FakeLlm`, `FakeStt`, `FakeTts`, `FakeVad`); register them through a test plugin and your facade/pipeline tests run under plain `dart test` with no emulator. Storage and network are injectable too (`FlutterStoragePaths.at`, custom `NetworkPolicy`). See [Adapters → Testability](adapters.md).

## Where does everything live on disk?

Under `<app-support>/local_ai/`: installed models in `models/<type>/<id>/`, voices in `voices/<id>/`, catalog caches in `manifests/`, resumable download state in `downloads/`, and OS-purgeable scratch in `cache/`. `ai.models.remove(modelId)` cleans up completely. Full details in [Storage Layout](storage.md).
