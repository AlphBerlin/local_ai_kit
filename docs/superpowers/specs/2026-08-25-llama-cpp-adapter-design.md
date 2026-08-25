# llama.cpp Adapter Design

**Date:** 2026-08-25

**Status:** Approved in chat; implementation pending written-plan review.

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
   v1 (not phased).

Out of scope: web/WASM target, replacing or touching `local_ai_gemma` /
`local_ai_sherpa`, any change to `local_ai_core` public types (new
`LocalAIError` cases reuse existing sealed variants — see Error Handling
below), Genkit integration (works automatically once `LlamaCppLlmAdapter`
exists, since `GenkitLlmAdapter` wraps any inner `LocalLlm`).

## Design

### 1. Package identity & dependency wiring

Follows `local_ai_gemma`'s shape exactly:

```
packages/local_ai_llama_cpp/
  pubspec.yaml            # deps: local_ai_core, flutter (sdk), fllama (or
                           # equivalent maintained Flutter llama.cpp plugin)
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

Dependency rule compliance: only `local_ai_core` and the chosen native
plugin are dependencies; no `fllama` (or equivalent) types appear in
`LlamaCppLlmAdapter`'s or `LlamaCppEmbeddingAdapter`'s public API surface.

**Native binding choice:** wrap an existing, actively maintained Flutter
llama.cpp plugin (leading candidate: `fllama`, which ships prebuilt
llama.cpp binaries with Metal/Vulkan/CUDA backends across the target
platform matrix) rather than hand-rolling FFI bindings or a self-built
native binary pipeline. This was chosen over raw FFI specifically to avoid
owning a 5-platform CMake/Metal/Vulkan/CUDA build matrix — that cost isn't
justified unless the wrapped plugin proves inadequate.
**Verify at implementation time** (package still actively maintained,
license compatible, current pub.dev API matches what's assumed below) since
this is a fast-moving dependency and the exact API may have shifted since
this doc was written.

**"Any GGUF model" mechanism:** no new plumbing needed. A `LocalModelManifest`
with `provider: 'llama-cpp'` and `delivery: ModelDelivery.external` lets an
app point at any local GGUF file path directly, bypassing the
download/catalog flow entirely — this existing `ModelDelivery` variant
already covers "bring your own model."

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
  (`auto`/`cpu`/`gpu`/`npu`): `auto` checks `DeviceCapabilities` and
  requests Metal (iOS/macOS), Vulkan (Android/Windows/Linux), or CUDA (if
  present on desktop) from the plugin's backend flags; on init failure it
  falls back to CPU (thread count tuned to core count) and reports
  `RuntimeEvent.backendFallback` — the same contract `GemmaLlmAdapter`
  already honors, so `RuntimeController` needs no changes.
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
| Malformed/truncated GGUF header, wrong architecture | `ModelCorrupted` |
| Context size or model too large for available RAM | `IncompatibleDevice` (via `checkCompatibility`'s existing `CompatibilityReport`, checked *before* load) |
| GPU backend init failure | `RuntimeEvent.backendFallback` → retry on CPU; only `NativeRuntimeError` if CPU init also fails |

Loaded llama.cpp models (both chat and embedding) participate in the
existing `RuntimeMemoryPolicy` LRU scheduler with no special-casing —
`ModelRuntimeScheduler` already treats `LoadedModel` generically.

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
| Chosen native plugin's API/maintenance status may have shifted since this doc was written | Verify at implementation start before writing adapter code against assumed API |
| Full 5-platform matrix in v1 increases validation surface (mobile GPU backends, app-store binary size) | Native plugin's prebuilt binaries carry this cost, not us; `ModelDeliveryPolicy` keeps large GGUF files out of the app bundle by default (download/external delivery) |
| Two isolates per fully-loaded llama.cpp setup (chat + embedding) adds idle memory overhead vs. Gemma's single adapter | Same `RuntimeMemoryPolicy`/LRU unload-when-idle mechanics apply to both; document that using both capabilities simultaneously costs two resident contexts |
