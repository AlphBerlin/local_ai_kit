# llama.cpp Adapter Design

**Date:** 2026-08-25 (revised 2026-08-26 after review)

**Status:** Implemented in `packages/local_ai_llama_cpp/` (see
"Implementation notes" at the end for where the build deviated from this
document and what `llama_cpp_dart` turned out to constrain). Previously:
revised after code review invalidated two load-bearing assumptions (native
binding choice, "no plumbing needed" for BYO models); see revision notes
inline.

## Goal

Add a new adapter package that lets `local_ai_kit` load and run **any GGUF
model** via llama.cpp, registered through the existing `AdapterRegistry`
exactly like `local_ai_gemma` and `local_ai_sherpa` are today — no changes to
`local_ai_core`'s public interfaces. Target the best achievable on-device
performance (persistent KV-cache, GPU backend auto-selection, real
grammar-constrained structured output) rather than parity-only with the
existing Gemma adapter.

## Scope

New package `packages/local_ai_llama_cpp/`:

1. `LlamaCppLlmAdapter implements LocalLlm` — chat/generation for any GGUF
   model, streaming, structured output via GBNF grammar.
2. `LlamaCppEmbeddingAdapter implements LocalEmbedding` — the first real
   implementation of this interface in the repo (currently
   interface-only/no adapter per `docs/adapters.md`).
3. `LlamaCppAdapterPlugin implements AdapterPlugin` — registers both under
   provider key `'llama-cpp'`.
4. Platform targets: Android, iOS, macOS, Windows, Linux — full matrix in
   v1 (not phased). Delivered by building/bundling llama.cpp ourselves per
   platform (see §Native binding choice, revised below) rather than a
   third-party plugin's prebuilt binaries.
5. `ModelManagerImpl.registerExternalModel(...)` — real BYO-GGUF plumbing
   in `local_ai_kit` (see §1, revised below). Added as explicit scope after
   review found `ModelDelivery.external` is currently unconsumed anywhere
   in the codebase.

Out of scope: web/WASM target, replacing or touching `local_ai_gemma` /
`local_ai_sherpa`, any change to `local_ai_core` public types (new
`LocalAIError` cases reuse existing sealed variants — see Error Handling
below), Genkit integration (works automatically once `LlamaCppLlmAdapter`
exists, since `GenkitLlmAdapter` wraps any inner `LocalLlm`), fixing
`ModelDelivery.bundled`/`bundledIfSmall` handling for adapters other than
this one — `ModelManagerImpl` doesn't branch on `delivery` at all today
(everything routes through the download path except the new
`registerExternalModel` entry point this spec adds); that's a pre-existing
gap in `local_ai_kit` unrelated to llama.cpp and not fixed here.

## Design

### 1. Package identity & dependency wiring

Follows `local_ai_gemma`'s shape exactly:

```
packages/local_ai_llama_cpp/
  pubspec.yaml            # deps: local_ai_core, flutter (sdk), llama_cpp_dart
                           # (FFI bindings) + native/ build scripts
  native/                 # CMake project vendoring llama.cpp as a submodule,
                           # per-platform build scripts producing the shared
                           # library each platform's build picks up:
                           #   android/  (Vulkan)   ios/ macos/ (Metal)
                           #   windows/ linux/       (Vulkan, CUDA optional)
  lib/
    local_ai_llama_cpp.dart                 # barrel export
    src/
      llama_cpp_adapter_plugin.dart
      llama_cpp_llm_adapter.dart
      llama_cpp_embedding_adapter.dart
      backend_selection.dart                # RuntimePreference -> GPU backend
      context_window.dart                   # sliding-window truncation (pure)
      json_schema_to_gbnf.dart              # pure translator
      isolate/
        llama_worker.dart                   # dedicated Isolate, FFI calls live here
  test/
    json_schema_to_gbnf_test.dart
    context_window_test.dart
```

Dependency rule compliance: only `local_ai_core` and `llama_cpp_dart` are
dependencies; no `llama_cpp_dart` types appear in `LlamaCppLlmAdapter`'s or
`LlamaCppEmbeddingAdapter`'s public API surface.

**Native binding choice (revised):** the original plan — wrap `fllama` to
avoid owning a native build matrix — does not hold up. Verified against
pub.dev: `fllama` is a single 0.0.1 release from 21 months ago, unverified
uploader, ~516 downloads, covers only Android/iOS/HarmonyOS (no
macOS/Windows/Linux), its own README states no GPU backend on Android, and
its API surface (`initContext`/`completion`/`tokenize`) has no
grammar/GBNF or embedding calls. Three sections of the original design
(full platform matrix, GBNF structured output, embedding adapter) had no
implementation path on top of it.

Revised choice: **`llama_cpp_dart`** (actively maintained Dart FFI bindings
generated against llama.cpp's C API) for the bindings, combined with
**building and bundling llama.cpp ourselves** per platform — a CMake build
vendoring llama.cpp as a submodule, producing a shared library per platform
with the appropriate GPU backend (Metal on iOS/macOS, Vulkan on
Android/Windows/Linux, CUDA optional on desktop where the toolchain is
present). This is the build-matrix cost the original design tried to
avoid, accepted here because it's the only path that actually delivers
GPU backends + GBNF grammar + embeddings across all 5 target platforms.
One upside of owning the binding directly: `llama_cpp_dart` is bindings
only (no opinionated threading model of its own), so the worker-isolate
design in §2 has no conflict to resolve with a wrapped plugin's internal
concurrency — we own the FFI call sites outright.

**"Any GGUF model" mechanism (revised):** `ModelDelivery.external` exists
in `local_ai_core` but is currently unconsumed — `ModelManagerImpl` doesn't
branch on `delivery` anywhere, and every adapter (including Gemma's
`_resolveModelFile`) resolves model files by scanning
`_paths.modelDir(type, modelId)`, which only contains something after a
real install. BYO-GGUF therefore needs a real entry point, added to
`local_ai_kit` (not `local_ai_core` — no interface changes):

```dart
// ModelManagerImpl (local_ai_kit)
Future<void> registerExternalModel(
  LocalModelManifest manifest, {
  required String localFilePath,
});
```

Behavior: validates `manifest.delivery == ModelDelivery.external` and that
`localFilePath` exists, then links it into the standard install location —
`Link(p.join(_paths.modelDir(manifest.type, manifest.id), fileName)).create(localFilePath)`
— rather than copying, so a multi-GB GGUF isn't duplicated on disk. Windows
can't reliably create symlinks without elevated privileges, so the Windows
path copies instead (documented cost, not the common case). Writes
`installed.json` directly with `catalogVersion: 0` (sentinel meaning "not
catalog-tracked") and adds the manifest to the merged in-memory catalog, so
`isInstalled`/`getStatus`/adapter `load()` all see it as `ready` with zero
changes to their existing code paths. `verify()` and `update()` become
no-ops for externally-registered models (no sha256/remote version to check
against) — document this explicitly since it differs from catalog-managed
models.

### 2. Runtime internals (performance-critical path)

- **One dedicated background `Isolate` per loaded model** (chat and
  embedding models each get their own), mirroring the *intended* design in
  `docs-internal/architecture.md` §5.6 (real FFI-in-isolate), not
  `local_ai_sherpa`'s current subprocess-shelling prototype. All llama.cpp
  calls happen inside the worker isolate; results stream back over a
  `SendPort` as `LlmChunk`-shaped events, so the UI isolate is never
  blocked.
- **Persistent `llama_context` across turns** — the worker isolate keeps
  the loaded context/KV-cache alive between `generate`/`generateStream`
  calls instead of reprocessing full history every request. This is the
  primary lever for real multi-turn performance and is the main practical
  advantage over a "reload per request" implementation.
- **Backend selection** reuses the existing `RuntimePreference` enum
  (`auto`/`cpu`/`gpu`/`npu`). `AdapterContext` does not carry
  `DeviceCapabilities` (that probe lives in `local_ai_flutter`, kit-side
  only) — the adapter can't query it directly. Two fallback layers already
  exist and compose without any new mechanism:
  1. **Adapter-internal** (optional, mirrors `GemmaLlmAdapter._nativeCreateModel`,
     gemma_llm_adapter.dart:208-226): try the GPU backend, catch init
     failure, retry immediately on CPU within the same `load()` call — no
     error propagates, so this is fast and silent.
  2. **Kit-level** (`RuntimeScheduler.loadModel`, runtime_scheduler.dart:99-112):
     if `load()` throws at all for a non-`cpu` `RuntimePreference`, the
     scheduler itself retries the whole load with `RuntimePreference.cpu`
     and emits `RuntimeBackendFallback` on the runtime event stream. This
     layer exists regardless of what the adapter does, so at minimum the
     adapter just needs to *throw* on unrecoverable GPU init failure —
     mirroring Gemma's internal retry is an optimization, not a
     requirement.
- **Context truncation** matches `GemmaLlmAdapter`'s existing
  `maxContextTokens` behavior: keep system prompt + most recent turns,
  flag `contextTruncated` on `LlmChunk` when a truncation occurs. Extracted
  as a pure function (`context_window.dart`) so it's unit-testable without
  a loaded model.
- **Sampling** (`topK`/`topP`/`temperature`, repetition penalty) is
  delegated to llama.cpp's native samplers (including DRY/repeat-penalty)
  rather than reimplemented as a Dart-side heuristic like Gemma's
  streaming repetition guard — llama.cpp's native sampler is strictly
  stronger here.

### 3. Structured output (GBNF grammar)

`json_schema_to_gbnf.dart` is a pure, exhaustively-unit-testable function
translating the subset of `JsonSchema` the core interface supports
(object/array/enum/string/number/bool, required vs. optional fields) into a
GBNF grammar string. `generateStructured<T>` passes this grammar to
llama.cpp's sampling params, constraining generation so invalid JSON is
effectively unreachable — a stronger guarantee than the prompt-injection +
parse-retry approach `GemmaLlmAdapter` uses today. Parse-failure retry
(`maxRetries`) is kept as a defensive fallback, not the primary mechanism.

### 4. Embedding adapter

`LlamaCppEmbeddingAdapter` loads a *separate* embedding-mode GGUF (e.g. a
`nomic-embed`/`bge`-style model — a distinct file from the chat model) in
its own worker isolate, using llama.cpp's embedding/pooling API.
`embed(text)` and `embedBatch(texts)` batch prompts through that isolate.
This is the first real `LocalEmbedding` implementation in the repo; update
`docs/adapters.md`'s "Embedding capability: interface-only" section once
shipped.

### 5. Error handling & memory scheduling

No new `LocalAIError` variants. GGUF-specific failures map onto existing
sealed cases:

| Failure | Maps to |
|---|---|
| Malformed/truncated GGUF header, wrong architecture, any other native load/inference failure | `NativeRuntimeError` (not `ModelCorruptedError` — that type requires `expectedSha256`/`actualSha256` and means a *downloaded file* failed checksum verification, which is a `local_ai_kit`-side download concern, not something the adapter itself constructs) |
| Model manifest declares more RAM than the device has | `IncompatibleDeviceError`, raised by `RuntimeScheduler.checkCompatibility` (runtime_scheduler.dart:257-273) *before* `load()` is ever called — this check only compares `manifest.platforms`/`manifest.minMemoryMB` against `DeviceCapabilities`; the adapter has no role in it |
| GPU backend init failure | adapter throws (optionally after its own internal CPU retry, see §2); `RuntimeScheduler` retries on CPU and emits `RuntimeBackendFallback`; `NativeRuntimeError` only if the CPU attempt also fails |

Loaded llama.cpp models (both chat and embedding) participate in the
existing `RuntimeMemoryPolicy` LRU scheduler with no special-casing —
`RuntimeScheduler` already treats `LoadedModel` generically.

### 6. Testing

- Pure-Dart, device-free unit tests (run under melos `test:core`-style
  invocation) for `json_schema_to_gbnf.dart` and `context_window.dart` —
  these carry the logic most worth exhaustively testing and require no
  native runtime.
- Actual model loading/inference is validated manually via
  `examples/demo`, consistent with how Gemma and Sherpa are validated
  today — no CI-runnable native-inference test is introduced, since none
  of the existing adapters have one either.

## Risks (add to `docs-internal/architecture.md` §7 table when implemented)

| Risk | Mitigation |
|---|---|
| We now own the native build (CMake + Metal/Vulkan/CUDA toolchains) across 5 platforms — the exact cost the original `fllama` pick tried to avoid, and CI needs a build matrix to produce these shared libraries | Accepted trade-off given `fllama` doesn't cover the required feature set (see §Native binding choice); scope the CI matrix and per-platform build scripts explicitly in the implementation plan, not left implicit |
| `llama_cpp_dart`'s current API surface (grammar/GBNF param, embedding/pooling calls) needs to be confirmed against its latest published version, not assumed from this doc | Verify at implementation start, before writing adapter code against assumed API — same caveat as before, now pointed at the right dependency |
| Full 5-platform matrix in v1 increases validation surface (mobile GPU backends, app-store binary size, symlink-vs-copy behavior for `registerExternalModel` on Windows) | `ModelDeliveryPolicy` keeps large GGUF files out of the app bundle by default; the Windows copy-fallback for BYO models is a documented, deliberate cost rather than a silent gap |
| Two isolates per fully-loaded llama.cpp setup (chat + embedding) adds idle memory overhead vs. Gemma's single adapter | Same `RuntimeMemoryPolicy`/LRU unload-when-idle mechanics apply to both; document that using both capabilities simultaneously costs two resident contexts |
| `registerExternalModel` bypasses sha256 verification and the download state machine entirely — a malicious or corrupt BYO file has no integrity check | Acceptable for v1: this mirrors the trust model of `ModelDelivery.external`'s intent (the app/user explicitly supplied the file); document that no verification happens, unlike catalog-managed models |


## Implementation notes (2026-09-03)

The design held up. The `llama_cpp_dart` 0.2.2 API was verified before any
adapter code was written, as the risk table required, and it does carry
everything three sections depended on: `SamplerParams.grammarStr` /
`grammarRoot` for GBNF, `ContextParams.embeddings` + `poolingType` for the
embedding adapter, and `ModelParams.nGpuLayers` for backend selection.
Four things came out differently.

**1. `llama_cpp_dart` ships no usable native binary — confirmed, and worse
than assumed.** The spec expected to own the build; it does. What the
verification added: that package's pubspec has no `flutter: plugin:`
section, so Flutter never runs the podspecs under its `ios/` and `macos/`
directories, never runs its `android/` Gradle build, and does not vendor the
`Llama.xcframework` it ships in `dist/`. Those directories are leftovers of
an example app, not a delivery mechanism. `native/build_llama.sh` /
`build_llama.ps1` plus `LlamaCppRuntime.useLibrary()` are the whole story
for getting a library onto a device.

**2. The native build is scripts, not a wrapper CMake project.** §1 proposed
a CMake project vendoring llama.cpp as a submodule. A wrapper `CMakeLists`
that only calls `add_subdirectory(llama.cpp)` adds nothing over invoking
llama.cpp's own CMake with the right flags, so the scripts do that directly
and clone the source at a configurable ref instead of carrying a submodule.
The deliverable is unchanged: one shared library per platform with the
platform's GPU backend. The **CI matrix remains unbuilt** — the risk table's
first row is still open, and `native/README.md` says so plainly.

**3. Two `llama_cpp_dart` constraints the design did not anticipate, both
affecting §2's persistent-KV-cache claim.**

* `setPrompt` hardcodes `add_special = true` when tokenizing. For a model
  whose tokenizer prepends a BOS (Llama 3, Gemma), continuing a cached
  context would inject a second BOS mid-sequence. The worker probes for this
  at load time (`tokenize(x, true).length != tokenize(x, false).length`) and
  reports `supportsCachedContinuation`; when false, the adapter re-evaluates
  the full prompt every turn. ChatML-family models (Qwen, SmolLM2, DeepSeek
  distills) do get the cache benefit. Fixing this properly needs either an
  upstream `addSpecial` parameter on `setPrompt` or driving `llama_batch`
  through raw FFI here.
* The sampler chain is built with the context and cannot be replaced, so a
  per-request grammar or a changed temperature/topP forces a `Llama`
  rebuild, which drops the KV cache. §3's "pass this grammar to llama.cpp's
  sampling params" therefore costs a context rebuild per structured-output
  call, not a free parameter change. Weights come back from the OS page
  cache, so it is far cheaper than a cold load, but it is a real cost and is
  documented in `docs/adapters.md` and the package README.

**4. Additions beyond the spec, both small and in `local_ai_kit` only.**
`LocalEmbeddingFacade` (`ai.embeddings`, plus `ai.embed`/`ai.embedBatch`
shortcuts) — §4 shipped the first `LocalEmbedding` implementation, and
without a facade it was only reachable through the runtime scheduler.
`ModelCatalogService.registerManifest`, which `registerExternalModel` needs
to make an app-supplied manifest resolvable. Two GGUF catalog entries
(`qwen-2.5-0.5b-instruct-gguf`, `nomic-embed-text-v1.5-gguf`) and the
`llama-cpp` provider key were added to `local_ai_core` — data and a routing
constant, not interface changes.

**Testing** matches §6: 66 device-free unit tests cover the GBNF translator,
context-window truncation, the KV-cache reuse decision, chat templates,
backend selection, GGUF file selection, streaming stop-sequence detection
and embedding post-processing; 11 more in `local_ai_kit` cover
`registerExternalModel` and the embedding facade. Actual model loading and
inference remain manually validated, as with every other adapter in this
repo — no CI-runnable native-inference test was introduced.
