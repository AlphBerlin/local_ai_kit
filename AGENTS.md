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

Seven-package workspace (plus the `bedge_ai` umbrella) with a strict,
one-directional dependency graph
(enforced by convention, not tooling — respect it when adding imports):

```
App
 └─ local_ai_kit    (facade / config / pipeline DSL / download manager / runtime scheduler)
     ├─ local_ai_gemma    (flutter_gemma → LocalLlm)
     ├─ local_ai_genkit   (optional LocalLlm orchestration; also depends on local_ai_kit
     │                     for its LocalAIGenkitX escape-hatch extension — the one
     │                     intentional exception to "kit never depends on an adapter")
     ├─ local_ai_llama_cpp (llama_cpp_dart → LocalLlm + LocalEmbedding for any GGUF;
     │                     real FFI in worker isolates)
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
- `bedge_ai` re-exports every first-party package, so a new adapter package
  needs an entry there, in the root `pubspec.yaml` `workspace:` list, and in
  `tool/release_config.dart` (all packages share one version).

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
  gpu/npu → cpu fallback on backend load failure. Also: concurrent
  `loadModel` calls for one id share a single in-flight future (two native
  loads of the same weights would leak one of them); every load publishes
  typed `ModelLoadPhase` transitions on `loadProgress(id)` and on
  `events`; `setPinned` exempts a model from eviction and, unlike
  `setLocked`, survives across loads; `cacheStats` counts hits/misses/
  evictions and the last measured load duration per model.
- **Compatibility checking** (`packages/local_ai_core/lib/src/models/model_compatibility.dart`):
  `ModelCompatibilityChecker.check(manifest:, device:)` is a pure function —
  no I/O, no Flutter, exhaustively unit-tested with `dart test`. Two rules
  encoded in it that are easy to break: a capacity check against a
  *momentary* resource (free RAM right now) warns rather than blocks, since
  the scheduler can free some by evicting; and a metric the probe reported as
  `0` produces a `CompatibilityCheck.unknown` warning naming the skipped
  check, never a pass and never a fail. `minMemoryMB` defaults to `0` on most
  manifests, so the checker falls back to `weights × 1.15 + 256MB` — and
  because that is an estimate it only ever warns. The gates live in
  `ModelManagerImpl._installInternal` (before the first downloaded byte) and
  `RuntimeScheduler._loadInternal` (before `adapter.load()`), both governed by
  `LocalAIConfig.compatibilityEnforcement`. Note that most catalog manifests
  list `['android','ios','macos']`, so on Linux/Windows the platform check
  blocks — correctly. Tests that call `LocalAI.initialize` must inject a
  `deviceProbe`, or they assert against whatever host runs them.
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
- **llama.cpp adapter** (`packages/local_ai_llama_cpp/`): the only adapter
  doing real FFI-in-isolate today. Four things carry most of the design and
  are each isolated as a pure, unit-tested function so they can be changed
  without a device: `json_schema_to_gbnf.dart` (JsonSchema → GBNF grammar
  for constrained structured output), `prompt_plan.dart` (whether the next
  request may continue the live KV cache or must reset it),
  `chat_template.dart` (turn markers per model family, inferred from the
  model id/file name — GGUF metadata templates are not reachable through
  `llama_cpp_dart`) and `stop_sequences.dart` (streaming stop-marker
  detection that holds back partial matches). Three constraints imposed by
  `llama_cpp_dart` and worked around rather than fixed: `setPrompt` always
  tokenizes with `add_special = true` (so cache continuation is disabled for
  models whose tokenizer prepends a BOS — probed at load), the sampler chain
  cannot be swapped after context creation (so a grammar or a changed
  temperature rebuilds the `Llama` instance and drops the cache), and the
  package is bindings-only with no Flutter plugin wiring (so the native
  library is built by `native/build_llama.sh` and bundled by the app, or
  pointed at with `LlamaCppRuntime.useLibrary`).
- **External (bring-your-own) models** (`ModelManagerImpl.registerExternalModel`):
  the only consumer of `ModelDelivery.external`. Symlinks (copies on
  Windows) an app-supplied file into `models/<type>/<id>/`, writes
  `installed.json` with the `catalogVersion: 0` sentinel and registers the
  manifest with `ModelCatalogService.registerManifest`. `verify` degrades to
  an existence check and `update` is a no-op for these — there is no trusted
  hash and no remote version. Nothing is verified, by design.
- **Bundle-size policy** (`tools/verify_bundle_policy.dart`): any asset
  under `packages/local_ai_kit/assets` matching
  `.onnx`/`.tflite`/`.task`/`.bin`/`.gguf` must stay under 25MB (kept in sync with
  `ModelDeliveryPolicy.smart(bundleBelowMB: 25)`); larger models must be
  marked `download` delivery, not `bundled`.

`.claude/skills/local-ai-kit-installer/` is an agent skill that installs and
integrates this kit into a target Flutter app. It deliberately reads the docs
listed below rather than restating them, so keeping those accurate keeps the
skill accurate — including the honest capability caveats above, which it is
required to relay.

`docs-internal/package-architecture-improvements.md` records the current
design direction, the bug register (fixed and outstanding), and what is
deliberately deferred. It is authoritative where it disagrees with the
original draft below.

One trap it documents that is worth repeating here, because it has bitten
this codebase twice: `future.whenComplete(() => map.remove(key))` where the
map holds futures. `Map.remove` returns the removed value — the very future
being built — and `whenComplete` waits on a `Future` its callback returns, so
the arrow form deadlocks the operation against itself and it never completes.
Use a block body.

`docs-internal/architecture.md` has the full original design rationale
(Chinese, marked as a v0.1 draft — cross-check against the code above before
trusting specifics). `docs/` has the current English user-facing reference:
`getting-started.md`, `adapters.md`, `configuration.md`,
`model-downloads.md`, `model-registry.md`, `pipelines.md`,
`voice-pipeline.md`, `runtime-memory.md`, `storage.md`,
`llm-and-genkit.md`, `faq.md`.
