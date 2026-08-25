# Verification Marker Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the maintained repository verification markers with real device metrics, low-latency PCM playback, typed Gemma integration, and a supported Genkit model bridge.

**Architecture:** Preserve the existing core interfaces and adapter registry. Put platform-specific probing and playback behind injectable boundaries in `local_ai_flutter`, keep `flutter_gemma` types at the Gemma adapter boundary, and make Genkit registration explicit on a caller-owned framework instance.

**Tech Stack:** Dart 3.6, Flutter 3.27, `device_info_plus` 11.x, `flutter_soloud` ^4.1.7, `flutter_gemma` 1.6.5, Genkit Dart `>=0.14.1 <0.15.0`, Flutter test, Dart test.

**Spec:** `docs/superpowers/specs/2026-08-25-verification-markers-design.md`

## Global Constraints

- `local_ai_core` remains pure Dart and gains no Flutter, Genkit, SoLoud, or native-runtime dependency.
- `local_ai_flutter` remains the only package that imports Flutter platform plugins.
- `local_ai_kit` continues to resolve adapters through `AdapterRegistry` and never imports an adapter package directly.
- The public `LocalAudioOutput.play` and `stop` contracts remain unchanged.
- Device failures must report unknown metrics as zero, never fabricated capacity.
- Every production behavior change follows a failing-test, minimal-implementation, passing-test cycle.
- Generated Flutter application-template comments are not modified.

---

### Task 1: Replace fixed device metrics with real platform sources

**Files:**
- Create: `packages/local_ai_flutter/lib/src/device_metrics_source.dart`
- Modify: `packages/local_ai_flutter/lib/src/device_probe.dart`
- Modify: `packages/local_ai_flutter/lib/local_ai_flutter.dart`
- Create: `packages/local_ai_flutter/test/device_metrics_source_test.dart`
- Create: `packages/local_ai_flutter/test/device_probe_test.dart`

**Interfaces:**
- Produces `DeviceMetricsSource.read() -> Future<DeviceCapabilities>`, `SystemDeviceMetricsSource`, and a cached `FlutterDeviceProbe` that returns real `DeviceCapabilities`.
- Consumes `DeviceInfoPlugin` and a small injectable process runner; no core interface changes.

- [ ] **Step 1: Write failing source and parser tests**

  Add tests using literal fixtures that assert Android/iOS metric mapping,
  Linux `/proc/meminfo` plus `df` parsing, macOS `sysctl` plus `vm_stat`
  parsing, Windows PowerShell output parsing, malformed-output zero fallback,
  and probe caching. The source contract is:

  ```dart
  abstract interface class DeviceMetricsSource {
    Future<DeviceCapabilities> read();
  }
  ```

- [ ] **Step 2: Run the focused tests and verify the intended failures**

  Run:

  ```sh
  flutter test packages/local_ai_flutter/test/device_metrics_source_test.dart packages/local_ai_flutter/test/device_probe_test.dart
  ```

  Expected result: failure because the injectable source and parser APIs do
  not yet exist.

- [ ] **Step 3: Implement the injectable source and platform parsers**

  Add a `DeviceMetricsSource` interface, a default source that uses the
  existing `device_info_plus` mobile fields, and defensive desktop process
  readers. Keep all process arguments explicit and parse only numeric fields.
  Remove fixed values and verification comments from `device_probe.dart`.

- [ ] **Step 4: Run the focused tests and verify they pass**

  Run the same focused `flutter test` command. Expected result: all source,
  parser, fallback, and cache tests pass.

- [ ] **Step 5: Commit the device source**

  ```sh
  git add packages/local_ai_flutter/lib packages/local_ai_flutter/test
  git commit -m "feat(flutter): probe real device memory and disk"
  ```

### Task 2: Stream PCM audio through SoLoud

**Files:**
- Modify: `packages/local_ai_flutter/pubspec.yaml`
- Modify: `packages/local_ai_flutter/lib/src/audio_player.dart`
- Modify: `packages/local_ai_flutter/lib/local_ai_flutter.dart`
- Create: `packages/local_ai_flutter/lib/src/pcm_audio.dart`
- Create: `packages/local_ai_flutter/test/pcm_audio_test.dart`
- Create: `packages/local_ai_flutter/test/audio_player_test.dart`
- Modify: `pubspec.lock`

**Interfaces:**
- Produces `PcmPlaybackBackend.play(Stream<AudioChunk>) -> Future<void>`,
  `PcmPlaybackBackend.stop() -> Future<void>`,
  `SoLoudPcmPlaybackBackend`, and the existing `FlutterAudioPlayer`
  implementation.
- Consumes `AudioChunk`, `AudioFormat`, and `LocalAudioOutput`; no changes to `local_ai_core`.

- [ ] **Step 1: Write failing PCM and backend-seam tests**

  Test signed-16 conversion for `-1.0`, `0.0`, `1.0`, clipped values, and
  empty input. Add a fake backend test proving `FlutterAudioPlayer.play`
  forwards chunks and `stop` reaches the backend.

- [ ] **Step 2: Run the focused tests and verify the intended failures**

  Run:

  ```sh
  flutter test packages/local_ai_flutter/test/pcm_audio_test.dart packages/local_ai_flutter/test/audio_player_test.dart
  ```

  Expected result: failure because the PCM helper and backend seam are not
  yet implemented.

- [ ] **Step 3: Add SoLoud and implement the stream backend**

  Add the pinned compatible `flutter_soloud` dependency. Convert each first
  non-empty `AudioChunk` to a released `s16le` buffer stream, initialize
  SoLoud once, add subsequent PCM chunks, mark the source ended, and dispose
  the source after completion. Make stop idempotently stop the active handle
  and dispose the source. Remove WAV files, `audioplayers`, process playback,
  and the old verification marker.

- [ ] **Step 4: Resolve dependencies, format, and run focused tests**

  Run:

  ```sh
  flutter pub get
  dart format packages/local_ai_flutter/lib packages/local_ai_flutter/test
  flutter test packages/local_ai_flutter/test/pcm_audio_test.dart packages/local_ai_flutter/test/audio_player_test.dart
  ```

  Expected result: dependency resolution succeeds and focused tests pass.

- [ ] **Step 5: Commit the PCM backend**

  ```sh
  git add packages/local_ai_flutter/pubspec.yaml packages/local_ai_flutter/lib packages/local_ai_flutter/test pubspec.lock
  git commit -m "feat(flutter): stream PCM audio through SoLoud"
  ```

### Task 3: Type the flutter_gemma runtime boundary

**Files:**
- Modify: `packages/local_ai_gemma/lib/src/gemma_llm_adapter.dart`
- Modify: `packages/local_ai_gemma/test/gemma_llm_adapter_test.dart`

**Interfaces:**
- Produces typed `fg.InferenceModel` and `fg.InferenceChat` lifecycle helpers.
- Consumes the existing `fg` 1.6.5 API and core `LocalLlm` contracts.

- [ ] **Step 1: Add a failing typed response-boundary test**

  Add a public pure helper on `GemmaLlmAdapter` with this exact signature:

  ```dart
  static String? textTokenForResponse(fg.ModelResponse response);
  ```

  Assert that `fg.TextResponse('hello')` returns `hello` and a typed
  non-text response returns `null`.

- [ ] **Step 2: Run the focused Gemma tests and verify the intended failure**

  Run:

  ```sh
  flutter test packages/local_ai_gemma/test/gemma_llm_adapter_test.dart
  ```

  Expected result: failure because the typed response boundary does not yet
  exist.

- [ ] **Step 3: Replace dynamic native fields and response handling**

  Change model/session fields and native helper signatures to concrete
  `flutter_gemma` types. Use the typed `ModelResponse` hierarchy in the
  stream loop and preserve model-file selection, backend fallback, close
  behavior, repetition guards, and final-chunk semantics.

- [ ] **Step 4: Run focused tests and analysis**

  Run:

  ```sh
  dart format packages/local_ai_gemma/lib packages/local_ai_gemma/test
  flutter test packages/local_ai_gemma/test/gemma_llm_adapter_test.dart
  flutter analyze packages/local_ai_gemma
  ```

  Expected result: tests and package analysis pass without dynamic native
  dynamic model/session fields.

- [ ] **Step 5: Commit the typed boundary**

  ```sh
  git add packages/local_ai_gemma/lib packages/local_ai_gemma/test
  git commit -m "refactor(gemma): type flutter_gemma runtime boundary"
  ```

### Task 4: Register a local model through Genkit

**Files:**
- Modify: `packages/local_ai_genkit/pubspec.yaml`
- Modify: `packages/local_ai_genkit/lib/src/genkit_llm_adapter.dart`
- Modify: `packages/local_ai_genkit/lib/local_ai_genkit.dart`
- Modify: `packages/local_ai_genkit/test/genkit_skills_test.dart`
- Create: `packages/local_ai_genkit/test/genkit_model_bridge_test.dart`
- Modify: `pubspec.lock`

**Interfaces:**
- Produces `GenkitLlmAdapter.registerAsGenkitModel({required Genkit genkit, String name = 'localai/inner'})` returning a Genkit `Model`.
- Consumes core `LlmRequest`, `LlmResponse`, `LlmChunk`, and the Genkit 0.14 model/message types.

- [ ] **Step 1: Update the dependency constraint and write failing bridge tests**

  Change the dependency to `>=0.14.1 <0.15.0`. Add tests that register a
  fake-backed adapter, invoke the registered model with system/user/assistant
  text messages, assert the core request mapping, and assert streamed chunks
  reach Genkit's callback before the final response.

- [ ] **Step 2: Resolve dependencies and verify the bridge tests fail for the right reason**

  Run:

  ```sh
  flutter pub get
  flutter test packages/local_ai_genkit/test/genkit_model_bridge_test.dart
  ```

  Expected result: dependency resolution succeeds and the tests fail because
  the current registration method is still a no-op sketch.

- [ ] **Step 3: Implement the Genkit model mapping**

  Import Genkit under a prefix, accept an explicit `Genkit`, map only text
  parts to core messages, forward text chunks through `sendChunk`, and return
  a typed final Genkit response. Throw a descriptive `ArgumentError` for
  unsupported content parts. Remove the obsolete sketch comments.

- [ ] **Step 4: Run Genkit focused tests and package analysis**

  Run:

  ```sh
  dart format packages/local_ai_genkit/lib packages/local_ai_genkit/test
  flutter test packages/local_ai_genkit/test/genkit_model_bridge_test.dart packages/local_ai_genkit/test/genkit_skills_test.dart
  flutter analyze packages/local_ai_genkit
  ```

  Expected result: bridge and existing orchestration tests pass.

- [ ] **Step 5: Commit the Genkit bridge**

  ```sh
  git add packages/local_ai_genkit/pubspec.yaml packages/local_ai_genkit/lib packages/local_ai_genkit/test pubspec.lock
  git commit -m "feat(genkit): register local model with Genkit"
  ```

### Task 5: Update maintained documentation and remove stale markers

**Files:**
- Modify: `docs/platform-layer.md`
- Modify: `docs/faq.md`
- Modify: `docs/llm-and-genkit.md`
- Modify: `docs/adapters.md`
- Modify: `packages/local_ai_genkit/README.md`
- Modify: `packages/local_ai_flutter/README.md`
- Modify: `packages/local_ai_gemma/README.md`

**Interfaces:**
- Produces documentation that matches the device, audio, Gemma, and Genkit implementations.
- Consumes the completed public APIs and the generated-template exclusion from the spec.

- [ ] **Step 1: Write the documentation edits**

  Replace fixed-capacity caveats with real-probe behavior, describe SoLoud
  PCM streaming and its platform requirements, describe typed Gemma runtime
  integration, and document explicit Genkit registration with a caller-owned
  `Genkit` instance.

- [ ] **Step 2: Scan maintained files for remaining verification markers**

  Run:

  ```sh
  git grep -n -i -E 'TODO|FIXME|HACK|XXX|UNIMPLEMENTED|NOT IMPLEMENTED' -- docs packages ':!packages/**/build/**'
  ```

  Expected result: only intentionally retained Flutter-generated template
  comments under `examples/demo` remain; no maintained docs or package source
  describes unfinished behavior from this plan.

- [ ] **Step 3: Commit the documentation**

  ```sh
  git add docs packages/local_ai_genkit/README.md packages/local_ai_flutter/README.md packages/local_ai_gemma/README.md
  git commit -m "docs: document completed platform integrations"
  ```

### Task 6: Run final workspace verification

**Files:**
- Modify: none unless verification exposes a regression.

- [ ] **Step 1: Format the workspace**

  ```sh
  dart format --output=none .
  ```

  Expected result: no formatting changes are required.

- [ ] **Step 2: Analyze all packages**

  ```sh
  melos run analyze
  ```

  Expected result: all package analyses pass with fatal infos enabled.

- [ ] **Step 3: Run core and Flutter test suites**

  ```sh
  melos run test:core
  melos run test:flutter
  ```

  Expected result: all pure-Dart and Flutter tests pass.

- [ ] **Step 4: Verify bundle policy**

  ```sh
  melos run verify:bundle-policy
  ```

  Expected result: no bundled model asset exceeds the repository threshold.

- [ ] **Step 5: Review commit and marker state**

  ```sh
  git status --short --branch
  git log --oneline -8
  git grep -n -i -E 'TODO|FIXME|HACK|XXX|UNIMPLEMENTED|NOT IMPLEMENTED' -- docs packages ':!packages/**/build/**'
  ```

  Expected result: the worktree is clean, the five implementation commits
  are present, and only generated demo-template comments remain.
