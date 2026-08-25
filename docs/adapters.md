# Adapters

Adapters bridge native/remote runtimes to the core capability interfaces; they are registered explicitly so unused runtimes never enter your binary.

## Architecture layers

```
┌────────────────────────────────────────────────────┐
│                      App                           │
└──────────────────────┬─────────────────────────────┘
                       ▼
┌────────────────────────────────────────────────────┐
│  local_ai_kit  (facade / config / pipeline DSL)    │
└───┬──────────┬──────────┬───────────┬──────────────┘
    ▼          ▼          ▼           ▼
┌────────┐┌────────┐┌─────────┐┌──────────────┐
│ gemma  ││ genkit ││ sherpa  ││ local_ai_    │
│ adapter││ adapter││ adapter ││ flutter      │
└───┬────┘└───┬────┘└────┬────┘└──────┬───────┘
    └─────────┴────┬─────┴────────────┘
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
    GemmaAdapterPlugin(),   // provider 'google-gemma' → LocalLlm
    SherpaAdapterPlugin(),  // provider 'sherpa-community' → VAD + STT + TTS
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

### 2. `SherpaTtsAdapter` / `SherpaSttAdapter` / `SherpaVadAdapter` (`local_ai_sherpa`) — implementation notice

Despite the package name, pubspec description and this doc's architecture diagram, **none of the three Sherpa adapters currently call into the `sherpa_onnx` Dart package** — it isn't imported anywhere under `packages/local_ai_sherpa/lib`. What they actually do today:

- **`SherpaSttAdapter` / `SherpaTtsAdapter`**: the worker isolate spawns an external process — `uv run --with sherpa-onnx ... python3 <embedded script>` — and talks to it over stdin/stdout JSON lines (`sherpa_stt_adapter.dart`, `sherpa_tts_adapter.dart`). The `uv` binary path has a hardcoded developer-machine fallback (`/Users/ajithberlin/.local/bin/uv`) if it isn't found on `PATH`. This only works where a Python 3 runtime and `uv` are reachable as a subprocess — realistically **macOS/desktop only**; Android and iOS sandboxing do not permit spawning arbitrary subprocesses, so these adapters are not expected to function there today despite the platform lists in the manifests. `SherpaTtsAdapter` has two further fallbacks: native macOS voices via `/usr/bin/say` (`Platform.isMacOS` only, not iOS), and — if neither the Python path nor `say` is available — a hand-rolled sawtooth/formant waveform synthesizer (`_synthesizeVocalWaveform`) that produces audible but non-neural speech-like output.
- **`SherpaVadAdapter`**: does **not** run Silero VAD or any ONNX model. `load()` computes a `modelPath` and sends it to the worker, but the worker's `initVad` handler never reads it. Voice activity is instead detected by a plain RMS-energy heuristic with adaptive noise-floor tracking, implemented entirely in Dart (`sherpa_vad_adapter.dart`). It works and is lightweight, but it is not the Silero model advertised by the class doc-comment, the package description, or the top-level README.
- **Voice-style support** (`F1`–`F5`/`M1`–`M5`, 31+ languages) and the general streaming/isolate architecture (§ above) are real; the specific "4-stage flow matching" internals and the exact set of `.onnx` filenames are implementation details of the external `supertonic` Python package this adapter shells out to, not something verifiable from this repo. The adapter itself only checks for `duration_predictor.onnx`'s existence before invoking it.
- TTS output sample rate is **not** always 44.1 kHz — the adapter picks `AudioFormat` from whatever rate the underlying engine reports at runtime (24 kHz for Kokoro, 22.05/16 kHz for some paths, 44.1 kHz as the fallback default for anything else).

If you're building on this package, treat the STT/TTS/VAD adapters as a working prototype/desktop demo rather than a production on-device (especially mobile) pipeline until they're re-implemented against the actual `sherpa_onnx` FFI bindings.

## Embedding capability: interface-only, no adapter ships yet

`LocalEmbedding`, `EmbeddingConfig`, `ModelType.embedding`, `ModelCapability.embedding` and the `models/embedding/<id>/` storage directory all exist end-to-end in `local_ai_core`, and `registerEmbedding(...)` exists on `AdapterRegistry` — but no package in this repo implements `LocalEmbedding` (no real adapter, no `FakeEmbedding`). "Embeddings" listed as a feature elsewhere in the docs/README describes the scaffolding, not a working capability yet; write your own adapter (following the pattern above) if you need it today.

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
