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
- **Prompt Templating & Role Alignment**: Automatically structures system prompts and turn markers (`<|im_start|>`, `<|user|>`, `<|assistant|>`) based on detected model family.
- **Repetition Guard & Balanced Sampling**: Default `topK = 40`, `topP = 0.9`, and `temperature = 0.7` with a real-time streaming 3-layer guard (line cycle, n-gram repeat, token burst) to guarantee stable, natural generation.

### 2. `SherpaTtsAdapter` (`local_ai_sherpa`)

Bridges Sherpa-ONNX and Supertonic to `LocalTts`:
- **Supertonic 3 4-Stage Flow Matching**: Pre-loads `duration_predictor.onnx`, `text_encoder.onnx`, `vector_estimator.onnx`, and `vocoder.onnx` into memory for sub-second flow-matching synthesis.
- **Zero-Shot Voice Styles**: Full support for 10 distinct voice styles (`F1`–`F5` female, `M1`–`M5` male) across 31+ languages with exact duration slicing.
- **Studio 44.1 kHz Audio**: Emits raw `AudioFormat.pcm44kMonoFloat` chunks without format conversion losses.
- **Zero-Dependency Native Fallback**: Seamless automatic fallback to native macOS/iOS multi-voice neural speech synthesis (`Kyoko`, `Samantha`, `Yuna`, `Tingting`, etc.).

## Testability: fakes

`local_ai_core` ships in-memory fakes implementing every capability, so app and pipeline tests need no device and no native runtime:

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
