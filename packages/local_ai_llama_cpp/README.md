# local_ai_llama_cpp

llama.cpp adapter for [LocalAI Kit](https://github.com/AlphBerlin/local_ai_kit):
runs **any GGUF model** behind the core `LocalLlm` and `LocalEmbedding`
interfaces, registered through the normal `AdapterRegistry` under the
provider key `llama-cpp`.

```dart
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

final ai = await LocalAI.initialize(
  const LocalAIConfig(
    llm: LlmConfig(modelId: 'qwen-2.5-0.5b-instruct-gguf'),
    embedding: EmbeddingConfig(modelId: 'nomic-embed-text-v1.5-gguf'),
  ),
  plugins: const [LlamaCppAdapterPlugin()],
);

final answer = await ai.generate('Hello, on-device world!');
final vector = await ai.embed('semantic search query');
```

## What it does

- **Persistent KV cache** — one `llama_context` stays alive for the whole
  `load()`…`unload()` lifetime, so an unchanged history prefix is not
  re-evaluated on every turn (`PromptPlanner` decides when that is safe).
- **Real grammar-constrained structured output** — `generateStructured`
  compiles the requested `JsonSchema` into a GBNF grammar
  (`JsonSchemaToGbnf`) and hands it to llama.cpp's sampler, so invalid JSON
  is unreachable rather than merely discouraged. The parse-and-retry loop
  stays as a defensive fallback.
- **First real `LocalEmbedding`** — `LlamaCppEmbeddingAdapter` loads an
  embedding-mode GGUF (nomic-embed, bge, e5, …) with mean pooling, and
  supports Matryoshka truncation through `EmbeddingConfig.dimensions`.
- **Native sampling** — `topK`/`topP`/`temperature` and repetition penalty
  are llama.cpp's own samplers, not a Dart-side heuristic.
- **Truthful telemetry** — real `promptTokens`/`completionTokens` and a
  `finishReason` that distinguishes `stop`, `length` and `cancelled`.
- **Bring your own GGUF** — `ai.models.registerExternalModel(manifest,
  localFilePath: …)` links a file you already have on disk into the standard
  install location; no download, no verification.

All llama.cpp calls happen in a dedicated worker isolate, so the UI isolate
never blocks, and no `llama_cpp_dart` type appears in this package's public
API.

## The native library

`llama_cpp_dart` ships Dart FFI bindings only — it is not a Flutter plugin,
so no binary reaches your app through it. Build and bundle llama.cpp
yourself with the scripts in [`native/`](native/README.md), then either use
the default library name for your platform or point the adapter at yours:

```dart
LlamaCppRuntime.useLibrary('/absolute/path/to/libmtmd.so');
```

## Known limits

- **Multi-turn cache reuse is disabled for tokenizers that prepend special
  tokens** (Llama 3, Gemma, …). `llama_cpp_dart`'s `setPrompt` always
  tokenizes with `add_special = true`, which would inject a second BOS token
  mid-conversation; rather than corrupt the history, those models
  re-evaluate the full prompt each turn. Check
  `LlamaCppLlmAdapter.reusesContextAcrossTurns`.
- **Changing sampling mid-session rebuilds the context.** llama.cpp builds
  its sampler chain with the context and `llama_cpp_dart` cannot swap it, so
  a different temperature/topP — or a structured-output grammar — costs a
  rebuild and drops the KV cache. Weights come back from the OS page cache,
  so it is far cheaper than a cold load, but it is not free: prefer batching
  structured-output calls together rather than interleaving them with chat.
- **Chat templates are inferred from the model id / file name**, not read
  from the GGUF metadata — `llama_cpp_dart` does not expose
  `llama_model_chat_template`. `ChatTemplate.detect` covers ChatML, Gemma,
  Llama 3, Mistral and Phi; anything unrecognised falls back to a plain
  `User:`/`Assistant:` format.
- **No vision.** The native build includes `mtmd`, but multimodal GGUF input
  is not wired to any core interface yet.
- **The native build scripts are not exercised in CI**; see
  [`native/README.md`](native/README.md).

## Documentation

See [`docs/adapters.md`](../../docs/adapters.md) for how this adapter fits
the kit's layering, and the design spec in
`docs/superpowers/specs/2026-08-25-llama-cpp-adapter-design.md`.

## License

Apache-2.0.
