# AGENTS.md

This file provides guidance to AI coding agents (Claude Code and others) when
working with code in this repository.

## Commands

This is a Dart pub workspace (root `pubspec.yaml` lists all packages under
`workspace:`) managed with [melos](https://melos.invertase.dev). Run these
from the repo root:

```sh
melos bootstrap             # pub get in every package
melos run analyze           # dart analyze --fatal-infos across all packages
melos run format            # dart format .
melos run test:core         # pure-Dart tests (local_ai_core only, no device/CI-friendly)
melos run test:flutter      # flutter test for every Flutter package with a test/ dir
melos run test              # test:core && test:flutter
melos run verify:bundle-policy   # fails if a bundled model asset (.onnx/.tflite/.task/.bin) >= 25MB
```

Running a single test file directly (bypassing melos):

```sh
dart test packages/local_ai_core/test/core_test.dart          # pure-Dart package
flutter test packages/local_ai_kit/test/pipeline_test.dart    # Flutter package
```

## Architecture

Six-package workspace with a strict, one-directional dependency graph
(enforced by convention, not tooling — respect it when adding imports):

```
App
 └─ local_ai_kit    (facade / config / pipeline DSL / download manager / runtime scheduler)
     ├─ local_ai_gemma    (flutter_gemma → LocalLlm)
     ├─ local_ai_genkit   (optional LocalLlm orchestration; also depends on local_ai_kit
     │                     for its LocalAIGenkitX escape-hatch extension — the one
     │                     intentional exception to "kit never depends on an adapter")
     ├─ local_ai_sherpa   (sherpa_onnx → LocalVad / LocalStt / LocalTts, FFI in worker isolates)
     └─ local_ai_flutter  (platform layer: storage paths, mic capture, audio playback,
                            network policy, device probe, permissions, app lifecycle)
         └─ local_ai_core (interfaces, models, config, events, errors, AdapterRegistry,
                            test fakes — pure Dart, only `meta` + `collection`)
```

- `local_ai_core` must never gain a Flutter or native-runtime dependency —
  it's the one package every other package (and every adapter) can safely
  depend on.
- `local_ai_flutter` is the only package allowed to touch Flutter platform
  plugins (`path_provider`, `record`, `audioplayers`, `permission_handler`,
  `connectivity_plus`, `device_info_plus`).
- `local_ai_kit` never imports an adapter package directly. Apps register
  adapters explicitly — `LocalAI.initialize(config, plugins: [GemmaAdapterPlugin(), SherpaAdapterPlugin()])`
  — which is what lets an unused native runtime (e.g. onnxruntime when no
  STT/TTS is needed) be fully tree-shaken out of a binary.

Mechanisms worth understanding before changing related code (each spans
multiple files, so grep won't surface the full picture on its own):

- **AdapterRegistry** (`packages/local_ai_core/lib/src/registry/adapter_registry.dart`):
  plugins register factories keyed by `manifest.provider` (e.g.
  `'google-gemma'`, `'sherpa-community'`); `LocalAI.initialize` resolves a
  `LocalModelManifest` to a concrete adapter through this registry at
  runtime — never hardcode an adapter choice into `local_ai_kit`.
- **Download/install state machine** (`packages/local_ai_kit/lib/src/download/`):
  `notInstalled → queued → downloading ⇄ paused → verifying → extracting →
  installing → installed → loading → ready`. Resumable via HTTP `Range`,
  atomic `meta.json` writes, chunked constant-memory sha256 verification
  per file (computed after each file finishes downloading, not
  concurrently with it), and a same-partition atomic rename from
  `downloads/<id>` to `models/<type>/<id>` only after every file verifies.
  Crash recovery (`ModelInstaller.recoverFromCrash()`) actually scans
  `models/` for directories missing `installed.json` or payload files —
  not `downloads/`, which is left alone so in-progress downloads resume.
- **RuntimeScheduler** (`packages/local_ai_kit/lib/src/runtime/runtime_scheduler.dart`):
  LRU eviction across loaded models (default max 2), idle-timeout unload
  (default 5 min), background trim via `AppLifecycleObserver`, and automatic
  gpu/npu → cpu fallback on backend load failure.
- **Voice pipeline / barge-in** (`packages/local_ai_kit/lib/src/voice/voice_pipeline.dart`):
  Mic → VAD → STT → LLM(/Genkit) → TTS → Speaker wired as one broadcast
  `VoiceEvent` stream. Barge-in triggers on sustained VAD confidence
  (≥120ms) by calling `audioOutput.stop()` and cancelling the in-flight
  LLM/TTS streams via `CancelToken`. There's no AEC — echo false-triggers
  are mitigated with a raised VAD threshold during playback plus
  text-prefix similarity filtering, not real echo cancellation.
- **Pipeline DSL** (`packages/local_ai_kit/lib/src/pipeline/local_pipeline.dart`):
  typed builder chain — `.input.microphone().vad().stt().llm().tts().output.speaker()`
  — where each stage method returns a distinct Stage type so an illegal
  ordering (e.g. `.tts()` before `.llm()`) is a compile error, not a
  runtime one. Stages compose into a single `StreamTransformer` chain.
- **Remote catalog merge** (`packages/local_ai_kit/lib/src/catalog/catalog_merger.dart`):
  the bundled `assets/catalog.json` is the offline fallback; a remote
  catalog merges by `modelId` keyed on `catalogVersion` — it never deletes
  an installed model's manifest entry, and never silently overwrites an
  installed model's files even on a version bump (it flips the model to
  `updating` and waits for an explicit `update()` call instead).
- **Sherpa adapters run in a worker isolate, but not on `sherpa_onnx` FFI** (`packages/local_ai_sherpa/lib/src/isolate/sherpa_worker.dart`):
  every sherpa component (VAD/STT/TTS) does its work inside a dedicated
  worker `Isolate` so the UI isolate never blocks, and audio frames cross
  the isolate boundary via `TransferableTypedData` for a zero-copy
  transfer — but despite the package name and doc comments, `sherpa_onnx`
  is never imported anywhere in this package. `SherpaSttAdapter`/
  `SherpaTtsAdapter` actually shell out to a `uv run python3` subprocess
  (desktop-only; has a hardcoded developer-machine fallback path for
  `uv`), and `SherpaVadAdapter` is a pure-Dart RMS-energy heuristic that
  never touches the Silero model it claims to load. Treat these three as
  a desktop prototype, not production mobile STT/TTS/VAD, until they're
  reimplemented against real `sherpa_onnx` FFI bindings.
- **Gemma dual backend** (`packages/local_ai_gemma/lib/src/gemma_llm_adapter.dart`):
  picks between a `MediaPipeEngine` (for Gemma/Paligemma `.task` models)
  and a `LiteRtLmEngine` (for `.litertlm`/`.bin` models like Qwen 3.5,
  SmolLM2, DeepSeek R1) based on the resolved model file, plus a
  streaming 3-layer repetition guard (line-level repetition, 3-word
  n-gram cycle detection, 6-identical-word burst) on top of default
  `topK=40`/`topP=0.9`/`temperature=0.8` sampling. It always reports
  `finishReason: stop` and never populates `promptTokens`/
  `completionTokens`, regardless of how generation actually ended.
- **Bundle-size policy** (`tools/verify_bundle_policy.dart`): any asset
  under `packages/local_ai_kit/assets` matching
  `.onnx`/`.tflite`/`.task`/`.bin` must stay under 25MB (kept in sync with
  `ModelDeliveryPolicy.smart(bundleBelowMB: 25)`); larger models must be
  marked `download` delivery, not `bundled`.

`docs-internal/architecture.md` has the full original design rationale
(Chinese, marked as a v0.1 draft — cross-check against the code above before
trusting specifics). `docs/` has the current English user-facing reference:
`getting-started.md`, `adapters.md`, `configuration.md`,
`model-downloads.md`, `model-registry.md`, `pipelines.md`,
`voice-pipeline.md`, `runtime-memory.md`, `storage.md`,
`llm-and-genkit.md`, `faq.md`.
