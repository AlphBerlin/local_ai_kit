# LocalAI Kit

Pluggable, offline-first, streaming-first on-device AI toolkit for Flutter: LLM chat, speech-to-text, text-to-speech, VAD and embeddings behind one strongly-typed facade — with a resumable download manager, an LRU runtime scheduler and a full-duplex voice pipeline with barge-in.

[![pub package](https://img.shields.io/pub/v/local_ai_kit.svg)](https://pub.dev/packages/local_ai_kit)
[![platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20macOS-lightgrey)](#)
[![license](https://img.shields.io/badge/license-Apache--2.0-green)](#)

| Package | pub.dev |
|---|---|
| `local_ai_core` | [![pub](https://img.shields.io/pub/v/local_ai_core.svg)](https://pub.dev/packages/local_ai_core) |
| `local_ai_flutter` | [![pub](https://img.shields.io/pub/v/local_ai_flutter.svg)](https://pub.dev/packages/local_ai_flutter) |
| `local_ai_kit` | [![pub](https://img.shields.io/pub/v/local_ai_kit.svg)](https://pub.dev/packages/local_ai_kit) |
| `local_ai_gemma` | [![pub](https://img.shields.io/pub/v/local_ai_gemma.svg)](https://pub.dev/packages/local_ai_gemma) |
| `local_ai_llama_cpp` | [![pub](https://img.shields.io/pub/v/local_ai_llama_cpp.svg)](https://pub.dev/packages/local_ai_llama_cpp) |
| `local_ai_sherpa` | [![pub](https://img.shields.io/pub/v/local_ai_sherpa.svg)](https://pub.dev/packages/local_ai_sherpa) |
| `local_ai_genkit` | [![pub](https://img.shields.io/pub/v/local_ai_genkit.svg)](https://pub.dev/packages/local_ai_genkit) |
| `bedge_ai` | [![pub](https://img.shields.io/pub/v/bedge_ai.svg)](https://pub.dev/packages/bedge_ai) |

## Features

- **Pluggable adapters** — capabilities (LLM / STT / TTS / VAD / embedding) are registered explicitly via `AdapterPlugin`s; unused native runtimes never enter your binary. The llama.cpp adapter runs any GGUF model and ships the first working `embedding` implementation; the built-in STT/TTS/VAD adapters currently run via a desktop Python subprocess and a Dart heuristic rather than native `sherpa_onnx` FFI — see [Adapters](adapters.md) and the [FAQ](faq.md) for the exact status.
- **Offline-first** — the built-in model catalog works without network; an optional remote catalog is merged by `catalogVersion` (never deletes installed models, flags updates instead of overwriting).
- **Streaming-first** — generation, transcription, synthesis and download progress are all `Stream`s; one-shot results are folded streams.
- **Resumable downloads** — HTTP `Range` resume, `.part` temp files, atomic `meta.json` writes, streamed sha256 verification, exponential backoff retry, and atomic same-partition install.
- **Runtime memory management** — LRU eviction, idle-timeout sweep, background trim, automatic GPU/NPU → CPU fallback with events.
- **Voice sessions** — Mic → VAD → STT → LLM → TTS event bus with barge-in (confidence threshold + persistence check, echo mitigation without AEC).
- **Typed pipeline DSL** — compile-time-checked stage chains: `.input.microphone().vad().stt().llm().tts().output.speaker()`.
- **Optional Genkit orchestration** — flows, tools, prompt templates and schema-validated structured output on top of any `LocalLlm`.

## Package structure

```
local_ai_kit/                       (melos workspace)
├── packages/
│   ├── local_ai_core/              Pure Dart: interfaces, config, manifests,
│   │                               events, errors, adapter registry, fakes.
│   ├── local_ai_flutter/           Platform layer: storage paths, mic
│   │                               recorder, audio player, network policy,
│   │                               device probe, permissions, lifecycle.
│   ├── local_ai_gemma/             flutter_gemma → LocalLlm adapter.
│   ├── local_ai_llama_cpp/         llama.cpp → LocalLlm + LocalEmbedding.
│   ├── local_ai_sherpa/            sherpa_onnx → LocalVad/LocalStt/LocalTts
│   │                               (FFI isolated in worker isolates).
│   ├── local_ai_genkit/            Optional orchestration layer over LocalLlm
│   │                               (flows/tools/templates/structured output).
│   ├── local_ai_kit/               Facade: LocalAI, ModelHub, download
│   │                               manager, RuntimeScheduler, VoiceSession,
│   │                               pipeline DSL, config presets.
│   └── bedge_ai/                   One-dependency umbrella re-exporting the
│                                   facade, platform layer and all adapters.
└── examples/demo/                  Demo app: LLM chat, TTS, STT, voice
                                   assistant, model catalog, live logs.
```

Dependency rule: everyone depends on `local_ai_core`; only adapter packages touch their native SDKs; `local_ai_kit` never imports an adapter.

For an app that wants all first-party adapters through one dependency, use `bedge_ai` and import `package:bedge_ai/bedge_ai.dart`.

## Quick start

```dart
import 'package:local_ai_kit/local_ai_kit.dart';
import 'package:local_ai_gemma/local_ai_gemma.dart';
import 'package:local_ai_sherpa/local_ai_sherpa.dart';

Future<void> main() async {
  // 1. Pick a preset (or compose LocalAIConfig yourself) and register the
  //    adapter plugins for the runtimes you actually use.
  final ai = await LocalAI.initialize(
    LocalAIConfig.voiceAssistant(),
    plugins: const [
      GemmaAdapterPlugin(),
      SherpaAdapterPlugin(),
    ],
  );

  // 2. Models download lazily (resumable, verified) on first use; or drive
  //    it explicitly:
  ai.models.downloadProgress(Models.gemma3nE2b.id).listen(print);
  await ai.models.ensureInstalled(Models.gemma3nE2b.id);

  // 3. Generate text (streaming or one-shot).
  final response = await ai.generate('Hello, on-device world!');
  print(response.text);

  // 4. Full-duplex voice session with barge-in.
  final session = await ai.voice.start();
  session.events.listen((event) => print(event));
}
```

Presets: `LocalAIConfig.lowMemory()` / `.voiceAssistant()` / `.offlineChat()` / `.transcription()`.
Pipeline presets: `LocalPipeline.presets.textChat(ai)` / `.transcription(ai)` / `.voiceChat(ai)` / `.voiceCommand(ai)`.

## Next steps

- [Installation & First Steps](getting-started.md) — dependencies, initialization, first generate/transcribe/speak.
- [Configuration](configuration.md) — every `LocalAIConfig` field and the built-in presets.
- [Model Registry & Catalog](model-registry.md) — manifests, delivery strategies and the remote catalog.
