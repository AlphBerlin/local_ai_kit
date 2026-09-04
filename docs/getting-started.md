# Getting Started

This page walks you from adding the packages to your first generation, transcription and speech synthesis.

## 1. Add dependencies

If you want all first-party adapters through one dependency, use the umbrella:

```yaml
dependencies:
  bedge_ai: ^0.0.3
```

```dart
import 'package:bedge_ai/bedge_ai.dart';
```

The individual package setup below is better when you want unused native
runtimes excluded from the application binary.

The kit is published as eight packages; add the facade plus the adapter packages
for the runtimes you actually use. (Only registered adapters end up in your
binary.)

**pub.dev packages:**

| Package | pub.dev |
|---|---|
| [`local_ai_core`](https://pub.dev/packages/local_ai_core) | Pure-Dart interfaces, config, manifests, test fakes |
| [`local_ai_flutter`](https://pub.dev/packages/local_ai_flutter) | Flutter platform layer |
| [`local_ai_kit`](https://pub.dev/packages/local_ai_kit) | Facade: `LocalAI`, `ModelHub`, pipeline DSL |
| [`local_ai_gemma`](https://pub.dev/packages/local_ai_gemma) | LLM adapter (`flutter_gemma`) |
| [`local_ai_llama_cpp`](https://pub.dev/packages/local_ai_llama_cpp) | LLM + embedding adapter (`llama.cpp`) |
| [`local_ai_sherpa`](https://pub.dev/packages/local_ai_sherpa) | VAD + STT + TTS adapter (`sherpa_onnx`) |
| [`local_ai_genkit`](https://pub.dev/packages/local_ai_genkit) | Optional Genkit orchestration layer |
| [`bedge_ai`](https://pub.dev/packages/bedge_ai) | One-dependency umbrella (all of the above) |

```yaml
dependencies:
  local_ai_kit: ^0.0.3
  local_ai_gemma: ^0.0.3      # LLM (flutter_gemma)
  local_ai_llama_cpp: ^0.0.3  # LLM + embeddings (llama.cpp)
  local_ai_sherpa: ^0.0.3     # VAD + STT + TTS (sherpa_onnx)
  # local_ai_genkit: ^0.0.3   # Optional orchestration
```

**Git dependencies** (for unreleased changes):

```yaml
dependencies:
  local_ai_kit:
    git:
      url: https://github.com/ajithberlin/local_ai_kit.git
      path: packages/local_ai_kit
  local_ai_gemma:    # LLM (flutter_gemma)
    git:
      url: https://github.com/ajithberlin/local_ai_kit.git
      path: packages/local_ai_gemma
  local_ai_sherpa:   # VAD + STT + TTS (sherpa_onnx)
    git:
      url: https://github.com/ajithberlin/local_ai_kit.git
      path: packages/local_ai_sherpa
  # Optional orchestration layer:
  # local_ai_genkit:
  #   git:
  #     url: https://github.com/ajithberlin/local_ai_kit.git
  #     path: packages/local_ai_genkit
```

**Path dependencies** (when working inside the monorepo):

```yaml
dependencies:
  local_ai_kit:
    path: packages/local_ai_kit
  local_ai_gemma:
    path: packages/local_ai_gemma
  local_ai_sherpa:
    path: packages/local_ai_sherpa
```

`local_ai_kit` re-exports `local_ai_core` and `local_ai_flutter`, so one import covers interfaces, config models, events, errors and test fakes:

```dart
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';
import 'package:local_ai_sherpa/local_ai_sherpa.dart';
```

## 2. Initialize

`LocalAI.initialize` assembles storage, the adapter registry, the model catalog (with a remote merge when configured), the download manager and the runtime scheduler:

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig.offlineChat(),
  plugins: const [GemmaAdapterPlugin()],  // or LlamaCppAdapterPlugin() for GGUF
);
```

Key parameters of `LocalAI.initialize`:

| Parameter | Type | Default | Purpose |
|---|---|---|---|
| `config` | `LocalAIConfig` | required | Which components are wired and how. |
| `plugins` | `List<AdapterPlugin>` | `const []` | Adapter registrations (Gemma, Sherpa, Genkit, custom). |
| `enableAudio` | `bool` | `true` | Creates the shared microphone/speaker stack. Set `false` for text-only apps. |
| `paths` | `LocalStoragePaths?` | `FlutterStoragePaths.resolve()` | Override the storage layout (mainly for tests). |
| `networkPolicy` | `NetworkPolicy?` | `FlutterNetworkPolicy()` | Override connectivity handling. |
| `deviceProbe` | `Future<DeviceCapabilities> Function()?` | `FlutterDeviceProbe().probe` | Override device capability detection. Tests should always inject one, otherwise they assert against whatever host runs them. |

Every component in `LocalAIConfig` is optional — a `null` component means its facade throws `InvalidStateError` on use, and its model is never downloaded.

## 3. Ensure models are ready

Model downloads are lazy: the first `generate`/`transcribe`/`speak` call triggers `ensureInstalled` under the hood. To control UX yourself, drive it explicitly:

```dart
const modelId = Models.gemma3nE2b.id; // 'gemma-3n-e2b-it-int4'

// Watch progress for a download UI.
ai.models.downloadProgress(modelId).listen((p) {
  print('${(p.fraction * 100).toStringAsFixed(1)}% '
      '(${(p.bytesPerSecond / 1e6).toStringAsFixed(1)} MB/s)');
});

// Idempotent: returns immediately if already installed and verified.
await ai.models.ensureInstalled(modelId);
```

Check the device before you offer the download — a model can be several gigabytes, and this is cheap:

```dart
final report = await ai.models.checkCompatibility(modelId);
if (!report.isCompatible) {
  return showBlocked(report.summary);   // disk, RAM, platform, accelerator
}
```

`ensureInstalled` runs the same check and throws `IncompatibleDeviceError` on a blocking issue, so this is for building your UI rather than for safety.

See [Model Downloads](model-downloads.md) for Wi-Fi-only policies, resume semantics, the full check table and error handling.

Downloading is one wait; loading the model is a second one. Give it a loader too:

```dart
StreamBuilder<ModelLoadProgress>(
  stream: ai.runtime.loadProgress(modelId),
  builder: (context, snapshot) {
    final p = snapshot.data;
    if (p == null || p.phase == ModelLoadPhase.ready) return const ChatView();
    // `fraction` is null on the very first load — nothing is known about
    // how long it takes on this device yet.
    return LinearProgressIndicator(value: p.fraction);
  },
);
```

Or load ahead of time with `await ai.warmUp()` / `LocalAIConfig(warmUpOnInitialize: true)`. See [Runtime & Memory](runtime-memory.md).

## 4. First generation

```dart
final response = await ai.generate(
  'Explain on-device AI in one sentence.',
  systemPrompt: 'You are concise.',
  temperature: 0.7,
);
print(response.text);

// Streaming variant:
final chunks = await ai.generateStream(
  LlmRequest.prompt('Tell me a short story.'),
);
await for (final chunk in chunks) {
  stdout.write(chunk.textDelta);
}
```

## 5. First transcription

Requires `vad` + `stt` in the config (e.g. `LocalAIConfig.transcription()`), a `SherpaAdapterPlugin`, and audio enabled:

```dart
final mic = ai.audioSource!;
final frames = mic.start(format: AudioFormat.pcm16kMono);
final events = await ai.transcribeStream(frames);

await for (final event in events) {
  switch (event) {
    case TranscriptPartial(:final text):
      print('partial: $text');
    case TranscriptFinal(:final transcript):
      print('final: ${transcript.text}');
      await mic.stop();
      return;
  }
}
```

## 6. First speech synthesis

Requires `tts` in the config (e.g. `LocalAIConfig.voiceAssistant()`):

```dart
// Downloads the voice on first use, then plays through the speaker.
// Supertonic voice ids are 'f1'-'f5' (female) / 'm1'-'m5' (male) — see
// Model Registry & Catalog.
await ai.tts.installVoice('f1');
await ai.speak('Hello from your device.');
```

## Next steps

- [Configuration](configuration.md) — full field reference and presets.
- [Voice Pipeline](voice-pipeline.md) — full-duplex sessions with barge-in.
- [Pipeline DSL](pipelines.md) — typed stage chains for common flows.
