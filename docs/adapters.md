# Adapters

Adapters bridge native/remote runtimes to the core capability interfaces; they are registered explicitly so unused runtimes never enter your binary.

## Architecture layers

```
┌────────────────────────────────────────────────────┐
│                      App                           │
└──────────────────────┬─────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  local_ai_kit  (facade / config / pipeline DSL)                 │
└───┬──────────┬───────────┬──────────┬───────────┬───────────────┘
    ▼          ▼           ▼          ▼           ▼
┌────────┐┌────────┐┌────────────┐┌─────────┐┌──────────────┐
│ gemma  ││ genkit ││ llama_cpp  ││ sherpa  ││ local_ai_    │
│ adapter││ adapter││ adapter    ││ adapter ││ flutter      │
└───┬────┘└───┬────┘└─────┬──────┘└────┬────┘└──────┬───────┘
    └─────────┴─────┬─────┴────────────┴────────────┘
                    ▼
         ┌──────────────────────┐
         │    local_ai_core     │  ← only shared dependency; zero AI deps
         └──────────────────────┘
```

Hard rules:

1. `local_ai_core` depends only on the Dart SDK — interfaces, models, events, errors, fakes.
2. An adapter package depends on `core` plus its own runtime SDK; runtime types must not appear in the adapter's public API.
3. `local_ai_flutter` is the only package allowed to touch Flutter platform plugins.
4. `local_ai_kit` never imports an adapter package — adapters arrive via `LocalAI.initialize(plugins: …)`.

## AdapterPlugin registration

```dart
abstract interface class AdapterPlugin {
  void register(AdapterRegistry registry);
}
```

The registry routes manifests to factories by `manifest.provider`:

```dart
registry.registerLlm(String provider, LlmAdapterFactory factory);
registry.registerStt(String provider, SttAdapterFactory factory);
registry.registerTts(String provider, TtsAdapterFactory factory);
registry.registerVad(String provider, VadAdapterFactory factory);
registry.registerEmbedding(String provider, EmbeddingAdapterFactory factory);
```

Each factory receives an `AdapterContext` (`paths`, `networkPolicy`, `audioSource`, `audioOutput`) at resolution time. The built-in plugins are one-liners:

```dart
await LocalAI.initialize(
  config,
  plugins: const [
    GemmaAdapterPlugin(),     // provider 'google-gemma'      → LocalLlm
    LlamaCppAdapterPlugin(),  // provider 'llama-cpp'         → LocalLlm + LocalEmbedding
    SherpaAdapterPlugin(),    // provider 'sherpa-community'  → VAD + STT + TTS
  ],
);
```

Resolving a model whose provider has no registered factory throws `AdapterNotFoundError`; check `registry.supports(provider, ModelType.stt)` when probing.

## Writing a custom adapter

Example: integrate a hypothetical "Acme" on-device STT engine.

**1. Implement the capability interface.** Runtime-specific types stay inside the package:

```dart
import 'package:local_ai_core/local_ai_core.dart';

class AcmeSttAdapter implements LocalStt {
  AcmeSttAdapter({required LocalStoragePaths paths}) : _paths = paths;

  final LocalStoragePaths _paths;
  bool _loaded = false;

  @override
  Future<void> load(SttLoadOptions options) async {
    // Model files live at _paths.modelDir(ModelType.stt, options.modelId).
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
  }

  @override
  Stream<TranscriptEvent> transcribeStream(
    Stream<AudioFrame> audio, {
    SttOptions? options,
  }) async* {
    if (!_loaded) {
      throw StateError('AcmeSttAdapter used before load()');
    }
    await for (final frame in audio) {
      // Feed frame.samples to the Acme engine; emit hypotheses:
      yield TranscriptPartial('…');
    }
    yield const TranscriptFinal(Transcript(text: '…'));
  }

  @override
  Future<Transcript> transcribe(AudioBuffer audio, {SttOptions? options}) async {
    // Fold the streaming path or call the engine's batch API.
    return const Transcript(text: '…');
  }
}
```

**2. Ship a plugin with a provider key**, and add a manifest whose `provider` matches:

```dart
class AcmeAdapterPlugin implements AdapterPlugin {
  const AcmeAdapterPlugin();

  @override
  void register(AdapterRegistry registry) {
    registry.registerStt('acme', (context) => AcmeSttAdapter(paths: context.paths));
  }
}

// Manifest (app-supplied or via remote catalog):
const acmeManifest = LocalModelManifest(
  id: 'acme-stt-en-v1',
  type: ModelType.stt,
  provider: 'acme',
  delivery: ModelDelivery.download,
  files: [/* name/url/sha256/sizeBytes */],
);
```

**3. Register and use it:**

```dart
final ai = await LocalAI.initialize(
  const LocalAIConfig(stt: SttConfig(modelId: 'acme-stt-en-v1')),
  plugins: const [AcmeAdapterPlugin()],
);
```

## Built-in adapter implementations

### 1. `GemmaLlmAdapter` (`local_ai_gemma`)

Bridges `flutter_gemma` and Google's LiteRT-LM runtime to `LocalLlm`:
- **Dual Inference Backends**: Automatically selects between `MediaPipeEngine` (for Gemma/Paligemma `.task` models) and `LiteRtLmEngine` (for `.litertlm` / `.bin` models like Qwen 3.5, SmolLM2, and DeepSeek R1).
- **Model-family detection**: passes `systemInstruction`/turn role flags to `flutter_gemma`'s chat API based on the detected model family (deepseek / qwen / llama-style / gemma-it); it does not itself inject literal turn-marker tokens like `<|im_start|>` — any such templating happens inside `flutter_gemma`, not this adapter.
- **Repetition Guard & Balanced Sampling**: Default `topK = 40`, `topP = 0.9`, `temperature = 0.8`, with a real-time streaming 3-layer guard (line-level repetition, 3-word n-gram cycle detection, 6-identical-word burst guard) to reduce degenerate loops on small quantized models.

### 2. `LlamaCppLlmAdapter` / `LlamaCppEmbeddingAdapter` (`local_ai_llama_cpp`)

Runs **any GGUF model** through llama.cpp via `llama_cpp_dart`'s FFI
bindings, under the provider key `llama-cpp`. One `AdapterPlugin` registers
both capabilities; a manifest's `ModelType` decides which one a model
resolves to.

- **Worker isolate per loaded model.** Every llama.cpp call happens inside a
  dedicated `Isolate` (`src/isolate/llama_worker.dart`); only primitives
  cross back. A chat model and an embedding model therefore each hold their
  own isolate and their own `llama_context` — using both at once costs two
  resident contexts, and both participate normally in the kit's
  `RuntimeMemoryPolicy` LRU.
- **Persistent KV cache.** The context stays alive across
  `generate`/`generateStream` calls; `PromptPlanner` compares the request's
  history against what is already in the cache and sends only the new tail
  when the prefix matches verbatim. Any edit to an earlier turn, a changed
  system prompt, a truncation, or a sampler change resets it — llama.cpp
  cannot rewrite tokens already committed.
- **GBNF-constrained structured output.** `generateStructured` compiles the
  `JsonSchema` into a GBNF grammar (`JsonSchemaToGbnf`) and constrains
  sampling with it, so malformed JSON is unreachable instead of merely
  discouraged. Two documented simplifications: generated objects are closed
  (never a key outside `properties`, whatever `additionalProperties` says)
  and keys are emitted in declaration order — required first, then
  optional — which is a subset of legal JSON and matches what llama.cpp's own
  `json-schema-to-grammar` converter does. The prompt-injection + parse-retry
  loop remains as a defensive fallback for a model that runs out of tokens
  mid-object.
- **Native sampling.** `topK`/`topP`/`temperature` and repeat penalty are
  llama.cpp's own samplers — no Dart-side repetition guard like the Gemma
  adapter's.
- **Honest telemetry.** Unlike the Gemma adapter, this one reports real
  `promptTokens`/`completionTokens` and distinguishes `stop` (EOS or a chat
  stop marker), `length` (token budget or a full context) and `cancelled`.
- **Backend selection.** `RuntimePreference` maps to llama.cpp's
  `n_gpu_layers` (`cpu` → 0, everything else → offload as much as the build
  allows; there is no NPU backend in llama.cpp, so `npu` takes the GPU path).
  Both fallback layers apply: the worker retries on CPU inside `load()`, and
  if that also fails the kit's `RuntimeScheduler` retries and emits
  `RuntimeBackendFallback`.

Four limits worth knowing before you build on it:

1. **The native library is your responsibility.** `llama_cpp_dart` is
   bindings only — its pubspec has no `flutter: plugin:` section, so
   Flutter never runs the podspecs or Gradle files in that package and the
   `Llama.xcframework` it ships in `dist/` is not vendored into your app.
   Build llama.cpp with `packages/local_ai_llama_cpp/native/build_llama.sh`
   (or `.ps1`) and bundle it per platform, or point the adapter at your own
   binary with `LlamaCppRuntime.useLibrary(path)`. Those build scripts are
   developer tooling and are **not** exercised by this repo's CI.
2. **Cache reuse is off for tokenizers that prepend special tokens** (Llama
   3, Gemma, …). `llama_cpp_dart`'s `setPrompt` always tokenizes with
   `add_special = true`, which would inject a second BOS mid-conversation,
   so those models re-evaluate the whole prompt every turn instead. The
   worker probes for this at load time; read it back from
   `LlamaCppLlmAdapter.reusesContextAcrossTurns`.
3. **Changing sampling rebuilds the context.** llama.cpp builds its sampler
   chain with the context and `llama_cpp_dart` exposes no way to replace it,
   so a different temperature/topP — or a structured-output grammar — costs a
   `Llama` rebuild and drops the KV cache. Weights come from the OS page
   cache, so it is much cheaper than a cold load, but interleaving
   `generateStructured` with chat turns pays it on every switch.
4. **Chat templates are inferred from the model id / file name**, not read
   from GGUF metadata (`llama_cpp_dart` does not expose
   `llama_model_chat_template`). `ChatTemplate.detect` handles ChatML,
   Gemma, Llama 3, Mistral and Phi; anything unrecognised falls back to a
   plain `User:`/`Assistant:` format, which a chat-tuned model will follow
   less reliably than its own template.

### 3. `SherpaTtsAdapter` / `SherpaSttAdapter` / `SherpaVadAdapter` (`local_ai_sherpa`) — implementation notice

Despite the package name, pubspec description and this doc's architecture diagram, **none of the three Sherpa adapters currently call into the `sherpa_onnx` Dart package** — it isn't imported anywhere under `packages/local_ai_sherpa/lib`. What they actually do today:

- **`SherpaSttAdapter` / `SherpaTtsAdapter`**: the worker isolate spawns an external process — `uv run --with sherpa-onnx ... python3 <embedded script>` — and talks to it over stdin/stdout JSON lines (`sherpa_stt_adapter.dart`, `sherpa_tts_adapter.dart`). The `uv` binary path has a hardcoded developer-machine fallback (`/Users/ajithberlin/.local/bin/uv`) if it isn't found on `PATH`. This only works where a Python 3 runtime and `uv` are reachable as a subprocess — realistically **macOS/desktop only**; Android and iOS sandboxing do not permit spawning arbitrary subprocesses, so these adapters are not expected to function there today despite the platform lists in the manifests. `SherpaTtsAdapter` has two further fallbacks: native macOS voices via `/usr/bin/say` (`Platform.isMacOS` only, not iOS), and — if neither the Python path nor `say` is available — a hand-rolled sawtooth/formant waveform synthesizer (`_synthesizeVocalWaveform`) that produces audible but non-neural speech-like output.
- **`SherpaVadAdapter`**: does **not** run Silero VAD or any ONNX model. `load()` computes a `modelPath` and sends it to the worker, but the worker's `initVad` handler never reads it. Voice activity is instead detected by a plain RMS-energy heuristic with adaptive noise-floor tracking, implemented entirely in Dart (`sherpa_vad_adapter.dart`). It works and is lightweight, but it is not the Silero model advertised by the class doc-comment, the package description, or the top-level README.
- **Voice-style support** (`F1`–`F5`/`M1`–`M5`, 31+ languages) and the general streaming/isolate architecture (§ above) are real; the specific "4-stage flow matching" internals and the exact set of `.onnx` filenames are implementation details of the external `supertonic` Python package this adapter shells out to, not something verifiable from this repo. The adapter itself only checks for `duration_predictor.onnx`'s existence before invoking it.
- TTS output sample rate is **not** always 44.1 kHz — the adapter picks `AudioFormat` from whatever rate the underlying engine reports at runtime (24 kHz for Kokoro, 22.05/16 kHz for some paths, 44.1 kHz as the fallback default for anything else).

If you're building on this package, treat the STT/TTS/VAD adapters as a working prototype/desktop demo rather than a production on-device (especially mobile) pipeline until they're re-implemented against the actual `sherpa_onnx` FFI bindings.

## Embedding capability

`LocalEmbedding`, `EmbeddingConfig`, `ModelType.embedding`,
`ModelCapability.embedding`, the `models/embedding/<id>/` storage directory
and `AdapterRegistry.registerEmbedding` have existed end-to-end in
`local_ai_core` since the start; `LlamaCppEmbeddingAdapter` is the first
implementation behind them. Wire it like any other capability:

```dart
final ai = await LocalAI.initialize(
  const LocalAIConfig(
    embedding: EmbeddingConfig(
      modelId: 'nomic-embed-text-v1.5-gguf',
      dimensions: 256,   // optional Matryoshka truncation
    ),
  ),
  plugins: const [LlamaCppAdapterPlugin()],
);

final vector = await ai.embed('semantic search query');
final vectors = await ai.embedBatch(['a', 'b']);
final score = EmbeddingVectors.cosineSimilarity(vectors[0], vectors[1]);
```

`ai.embeddings` is the full facade (`ready`, `isLoaded`, `embed`,
`embedBatch`, `unload`); `ai.embed` / `ai.embedBatch` are shortcuts. The
model is downloaded and loaded lazily on first use and unloaded by the same
LRU/idle rules as every other model.

`EmbeddingConfig.dimensions` truncates the vector and re-normalises it —
valid for models trained with Matryoshka representation learning
(nomic-embed, bge-m3), meaningless for others, so leave it unset unless the
model documents support for it.

There is still no `FakeEmbedding` in `local_ai_core`: write a small
in-memory `LocalEmbedding` in your test (see
`packages/local_ai_kit/test/embedding_facade_test.dart`) until one ships.

## Testability: fakes

`local_ai_core` ships in-memory fakes for the four capabilities that have a real adapter (LLM/STT/TTS/VAD — no `FakeEmbedding` exists), so app and pipeline tests need no device and no native runtime:

| Fake | Behavior |
|---|---|
| `FakeLlm` | Echoes `responseText` in `chunkSize` chunks; `loadError` injects load failures (test backend fallback). Counts `loadCount`/`unloadCount`. |
| `FakeStt` | Returns a canned transcript; emits partial/final events. |
| `FakeTts` | Emits a configurable number of silent `AudioChunk`s. |
| `FakeVad` | Emits a `VadSpeechStarted`/`VadSpeechEnded` pair around any non-empty audio stream. |

```dart
class FakePlugin implements AdapterPlugin {
  const FakePlugin();
  @override
  void register(AdapterRegistry registry) {
    registry.registerLlm(ModelProviders.googleGemma, (_) => FakeLlm());
    registry.registerStt(ModelProviders.sherpaCommunity, (_) => FakeStt());
  }
}
```

Because the facades only depend on the core interfaces, swapping a real adapter for a fake is a one-line change in the plugin list.
