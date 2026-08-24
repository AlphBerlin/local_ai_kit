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
