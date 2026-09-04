# LocalAI Kit — Demo App

Interactive Flutter demo for [LocalAI Kit](https://github.com/AlphBerlin/local_ai_kit),
exercising every capability behind the `LocalAI` facade on a Material 3 UI
that adapts to light and dark mode. See `lib/main.dart` for the full source.

## What's inside

- **Text Generation (LLM)** — streaming chat against SmolLM2, Qwen 2.5/3.5,
  DeepSeek R1 or Gemma 3n/4, with optional MCP skills (calculator, device
  clock, device info, mock weather) and an optional Genkit orchestration
  layer.
- **Text-to-Speech (TTS)** — Supertonic, Kokoro or Piper synthesis with
  speed/pitch controls, a live waveform, and an audio player.
- **Speech-to-Text (STT)** — microphone capture with live partial
  hypotheses and a final transcript.
- **Voice Assistant** — a full-duplex Mic → VAD → STT → LLM → TTS session
  with barge-in.
- **Model Catalog** — browse, install, and remove every model in the
  built-in catalog with live download progress.
- **Live Logs** — a searchable, filterable stream of everything the app is
  doing under the hood.

## Getting started

```sh
cd examples/demo
flutter pub get
flutter run
```

This is a Flutter project; see the
[online documentation](https://docs.flutter.dev/) for general Flutter
setup help. For LocalAI Kit itself, start with the
[root README](../../README.md) and [docs/getting-started.md](../../docs/getting-started.md).
