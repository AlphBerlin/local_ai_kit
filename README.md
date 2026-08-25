# LocalAI Kit

Pluggable, offline-first, streaming-first on-device AI toolkit for Flutter:
LLM chat, speech-to-text, text-to-speech, VAD and embeddings behind one
strongly-typed facade — with a download manager, an LRU runtime scheduler
and a full-duplex voice pipeline with barge-in.

## Features

- **Pluggable adapters** — capabilities (LLM / STT / TTS / VAD / embedding)
  are registered explicitly via `AdapterPlugin`s; unused native runtimes
  never enter your binary. (`embedding` is interface-only today — no
  adapter ships yet, see [Adapters](docs/adapters.md).)
- **On-Device Models** (catalog entries; see [implementation status](docs/faq.md#which-platforms-are-supported) for the STT/TTS/VAD caveat below):
  - **LLMs**: Qwen 2.5/3.5 (0.5B–4B via LiteRT-LM), SmolLM2 360M, DeepSeek R1 Distill Qwen 1.5B, Gemma 3n/4 E2B/E4B.
  - **TTS**: Supertonic 3 (Supertone Inc. — 31+ languages, 10 voice styles `F1`–`F5`/`M1`–`M5`), Kokoro TTS v0.19, Piper Lessac Low. Ships today by shelling out to a Python/`sherpa-onnx` subprocess on desktop, with a native macOS-voice and a synthesized-waveform fallback; not yet wired to the `sherpa_onnx` Dart FFI bindings.
  - **STT**: Zipformer, SenseVoice Small, Whisper base/tiny, Moonshine tiny — same subprocess-based implementation as TTS above.
  - **VAD**: currently a lightweight Dart RMS-energy heuristic with adaptive noise-floor tracking, **not** the Silero ONNX model the adapter name implies.
- **Offline-first** — built-in model catalog works without network; an
  optional remote catalog is merged by `catalogVersion` (never deletes
  installed models, flags updates instead of overwriting).
- **Streaming-first** — generation, transcription, synthesis and download
  progress are all `Stream`s; one-shot results are folded streams.
- **Balanced Sampling & Repetition Guard** — built-in `topK` (40), `topP` (0.9), `temperature` controls and real-time streaming n-gram / burst guards to eliminate infinite generation loops.
- **Pristine 44.1 kHz Studio Audio** — zero-latency in-memory flow matching, direct Float32 PCM streaming, and native multi-voice fallback across 31+ languages.
- **Resumable downloads** — HTTP `Range` resume, `.part` temp files,
  atomic `meta.json` writes, streamed sha256 verification, exponential
  backoff retry, and atomic same-partition install.
- **Runtime memory management** — LRU eviction, idle-timeout sweep,
  background trim, automatic gpu/npu → cpu fallback with events.
- **Voice sessions** — Mic → VAD → STT → LLM → TTS event bus with
  barge-in (confidence threshold + 120 ms persistence, echo mitigation
  without AEC).
- **Typed pipeline DSL** — compile-time-checked stage chains:
  `.input.microphone().vad().stt().llm().tts().output.speaker()`.
- **Optional Genkit orchestration** — flows, tools, prompt templates and
  schema-validated structured output on top of any `LocalLlm`.

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
│   ├── local_ai_sherpa/            sherpa_onnx → LocalVad/LocalStt/LocalTts
│   │                               (FFI isolated in worker isolates).
│   ├── local_ai_genkit/            Optional orchestration layer over LocalLlm
│   │                               (flows/tools/templates/structured output).
│   └── local_ai_kit/               Facade: LocalAI, ModelHub, download
│                                   manager, RuntimeScheduler, VoiceSession,
│                                   pipeline DSL, config presets.
└── example/                        Minimal demo app (chat + voice).
```

Dependency rule: everyone depends on `local_ai_core`; only adapter packages
touch their native SDKs; `local_ai_kit` never imports an adapter.

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

  // 4. Structured output with schema validation + retries.
  final answer = await ai.generateStructured<Map<String, dynamic>>(
    'Give me a fun fact.',
    schema: JsonSchema.object(
      properties: {'fact': JsonSchema.string()},
      required: ['fact'],
    ),
    fromJson: (json) => json,
  );

  // 5. Full-duplex voice session with barge-in.
  final session = await ai.voice.start();
  session.events.listen((event) => print(event));

  // 6. Or compose a pipeline with the typed DSL.
  final pipeline = ai.pipeline()
      .input.microphone()
      .vad()
      .stt()
      .llm(systemPrompt: 'You are helpful.')
      .tts()
      .output.speaker()
      .build();
  await for (final event in pipeline.run()) {
    // PipelineEvent stream
  }
}
```

Presets: `LocalAIConfig.lowMemory()` / `.voiceAssistant()` /
`.offlineChat()` / `.transcription()`.
Pipeline presets: `LocalPipeline.presets.textChat(ai)` /
`.transcription(ai)` / `.voiceChat(ai)` / `.voiceCommand(ai)`.

## Documentation

- Architecture (layering, interfaces, state machines, merge/ download /
  memory strategies): `docs-internal/architecture.md`
- [Releasing to pub.dev](docs/releasing.md) — first publication and tagged
  releases for all six packages.
- See `example/lib/main.dart` for a complete minimal app.

## Development

```sh
melos bootstrap        # pub get in all packages
melos run analyze      # analyze everything
melos run test:core    # pure-Dart core tests (no device needed)
melos run verify:bundle-policy
```

## License

Apache-2.0 (see `LICENSE`).
