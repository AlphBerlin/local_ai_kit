---
name: local-ai-kit-installer
description: Install and integrate LocalAI Kit (local_ai_kit / bedge_ai / local_ai_gemma / local_ai_llama_cpp / local_ai_sherpa / local_ai_genkit) into a Flutter app end to end - choose packages, wire LocalAI.initialize with the right adapter plugins, pick model ids from the real catalog, configure Android/iOS/macOS permissions, add compatibility-check + download + load UI, and write an installation guide. Use when someone wants to add on-device AI (LLM chat, speech-to-text, text-to-speech, VAD, embeddings, GGUF, Gemma, sherpa) to a Flutter project, asks how to install or set up any of these packages, hits AdapterNotFoundError / IncompatibleDeviceError / a stuck model download, or asks to upgrade an existing LocalAI Kit integration.
---

# LocalAI Kit installer

Install LocalAI Kit into a Flutter app so that, at the end, `flutter analyze`
is clean, the app builds, and the developer has a written guide explaining
what was added and why.

## The rule that matters most

**Read the repo's docs; do not answer from memory.** This kit changes fast
and several of its capabilities are less complete than their names suggest.
Every model id, every config field and every capability claim you put in the
target project must come from a file you actually read in this session.

Where to read, in this order:

| Question | File |
|---|---|
| What is honestly implemented vs. aspirational | `AGENTS.md` — read this first, always |
| Package roles and dependency rules | `AGENTS.md` "Architecture" |
| Install + first call | `docs/getting-started.md` |
| Which adapter for which model | `docs/adapters.md` |
| Config fields and presets | `docs/configuration.md` |
| Model ids, sizes, providers | `packages/local_ai_core/lib/src/models/models.dart` (the catalog itself) and `docs/model-registry.md` |
| Downloads, resume, compatibility gate | `docs/model-downloads.md` |
| Loading, memory, warm-up, pinning | `docs/runtime-memory.md` |
| Voice sessions, barge-in | `docs/voice-pipeline.md` |
| Native llama.cpp build | `packages/local_ai_llama_cpp/native/README.md` |
| Design rationale + known bugs | `docs-internal/package-architecture-improvements.md` |

If the kit is a pub.dev dependency rather than a checkout, read the same
files from the package's `lib/` and its pub.dev page instead, and say in the
guide which version you read.

## What honest looks like here

`AGENTS.md` documents that, today:

- `local_ai_sherpa` STT and TTS **shell out to a `uv run python3` subprocess**
  (desktop-only) rather than using `sherpa_onnx` FFI, and its VAD is a
  pure-Dart RMS-energy heuristic, not the Silero model the name implies.
- `local_ai_gemma` always reports `finishReason: stop` and never fills in
  token counts.
- `local_ai_llama_cpp` needs a native library the app builds and bundles
  itself.

Relay whatever the current `AGENTS.md` says, in the guide you write. A
developer who discovers this after integrating does not come back. If the
user's requirement is production mobile STT and the caveat still stands, say
so before writing code, offer what does work, and let them decide.

## Procedure

### 1. Understand the target

Establish, by looking rather than asking where you can:

- Is this a Flutter app? (`pubspec.yaml` with a `flutter:` section.) If it is
  a pure Dart package, only `local_ai_core` applies — stop and say so.
- Which platforms does it ship? (`android/`, `ios/`, `macos/`, `windows/`,
  `linux/` directories.)
- Does it already depend on any `local_ai_*` or `bedge_ai` package? If so
  this is an upgrade: read the existing `LocalAI.initialize` call first and
  preserve its config.
- What capability does the user actually want: chat, transcription, speech,
  embeddings, or a full voice assistant?

Ask only what you cannot determine. One round of questions, not three.

### 2. Choose the packages

Default to the umbrella when the user has no binary-size constraint:

```yaml
dependencies:
  bedge_ai: ^0.0.3   # check the real current version before writing it
```

Split into individual packages when the app ships only some capabilities and
binary size matters — an unused adapter drags its whole native runtime
(onnxruntime, LiteRT) into the binary. Then take `local_ai_kit` plus exactly
the adapters in use:

| Want | Add |
|---|---|
| Text chat with Gemma/Qwen/SmolLM `.task`/`.litertlm` | `local_ai_gemma` |
| Text chat or embeddings with any GGUF | `local_ai_llama_cpp` |
| VAD / STT / TTS | `local_ai_sherpa` (read the caveat above first) |
| Flows, tools, prompt templates | `local_ai_genkit` |

`local_ai_core` and `local_ai_flutter` come in transitively — never add them
by hand unless the target is a pure-Dart package.

Pin the version by reading the current one from
`packages/local_ai_kit/pubspec.yaml` (all packages share one version) or from
pub.dev. Never invent a version number.

### 3. Configure the platforms

Do this **before** writing Dart, so the first run works. Details in
`references/platform-setup.md`. In short: `INTERNET` always (models are
downloaded), `RECORD_AUDIO` / `NSMicrophoneUsageDescription` / the macOS
audio-input entitlement only when the app uses the microphone.

### 4. Wire initialization

The three things that go wrong:

1. **A missing plugin.** `LocalAIConfig(llm: ...)` with an empty `plugins:`
   list initializes fine and throws `AdapterNotFoundError` at the first
   `generate` — possibly after a download. Every configured capability needs
   its adapter plugin registered.
2. **A model id that is not in the catalog.** Read the id out of
   `models.dart` or `Models.<name>.id`; do not type one from memory.
3. **A provider/adapter mismatch.** The manifest's `provider` routes to the
   adapter; a GGUF model needs `LlamaCppAdapterPlugin`, a `.task`/`.litertlm`
   model needs `GemmaAdapterPlugin`. `docs/adapters.md` has the mapping.

Initialize once, at app start, and keep the instance. `LocalAI.initialize` is
not cheap and the runtime holds native memory.

```dart
final ai = await LocalAI.initialize(
  LocalAIConfig(llm: LlmConfig(modelId: Models.<pick from catalog>.id)),
  plugins: const [/* the matching adapter plugins */],
  enableAudio: false, // true only if you use the mic or speaker
);
```

Call `ai.dispose()` when the app shuts down — it releases the runtime, the
download manager and the audio stack.

### 5. Gate the download on a compatibility check

Models are up to several gigabytes. Check before offering the download, not
after:

```dart
final report = await ai.models.checkCompatibility(modelId);
if (!report.isCompatible) {
  // report.summary says why: disk, RAM, platform, accelerator.
  return showBlocked(report.summary);
}
if (report.hasWarnings) {
  showAdvisory(report.warnings.map((i) => i.message));
}
await ai.models.ensureInstalled(modelId);
```

`ai.models.compatible(type: ModelType.llm)` returns the whole catalog already
filtered for this device, which is what a model-picker screen wants.

`install` / `ensureInstalled` run the same check themselves and throw
`IncompatibleDeviceError` on a blocking issue, so this is for building UI,
not for safety. `LocalAIConfig(compatibilityEnforcement: ...)` changes that
to `warn` or `off`.

**On desktop this check is strict for a real reason:** most catalog manifests
list `['android', 'ios', 'macos']`, so on Linux and Windows they are
genuinely reported incompatible. If the user is developing on Linux and hits
`IncompatibleDeviceError`, explain that rather than reaching for `off` —
then, if they want to proceed anyway, `CompatibilityEnforcement.warn` is the
documented escape hatch.

### 6. Build the two progress UIs

An app without both of these looks frozen twice: once downloading, once
loading. Neither is optional.

```dart
// Download: bytes, throughput, ETA.
StreamBuilder<ModelDownloadProgress>(
  stream: ai.models.downloadProgress(modelId),
  builder: (context, snapshot) { /* snapshot.data?.fraction */ },
);

// Load: phase, elapsed, and an estimate from the previous load.
StreamBuilder<ModelLoadProgress>(
  stream: ai.runtime.loadProgress(modelId),
  builder: (context, snapshot) {
    final p = snapshot.data;
    if (p == null || p.phase == ModelLoadPhase.ready) return const Chat();
    // `fraction` is null on the very first load — show an indeterminate
    // bar then, a determinate one after.
    return LinearProgressIndicator(value: p.fraction);
  },
);
```

Offer `ai.warmUp()` (or `LocalAIConfig(warmUpOnInitialize: true)`) when the
app can afford to load during a splash screen, and `ai.pinModel(id)` for the
one model used constantly, so a voice session does not evict it. Details in
`docs/runtime-memory.md`.

### 7. Verify

Do not report success on code you have not run.

```sh
flutter pub get
flutter analyze          # must be clean
flutter test             # if the project has tests
```

Then, if you can, run the app and exercise the path you wired
(`docs/getting-started.md` §4–§6 have minimal snippets). If you cannot run
it, say exactly that — "analyze is clean; I could not run the app in this
environment" — rather than implying it works.

### 8. Write the guide

Create `LOCAL_AI_KIT_SETUP.md` in the target project:

- Which packages were added, at which version, and why those.
- Which platform files changed, with what and why.
- Which model ids the app uses, their size, and what they need to run.
- The capability caveats from `AGENTS.md` that apply to this integration.
- How to change the model, and how to add another capability later.
- Troubleshooting: `AdapterNotFoundError`, `IncompatibleDeviceError`,
  `InsufficientDiskError`, a download that never starts on cellular
  (`DownloadPolicy.wifiOnly` defaults to `true`).

`references/troubleshooting.md` has the symptom-to-cause table to draw from.

## Scope

This skill installs and integrates. It does not:

- invent model ids, versions, or capabilities — read them
- claim a capability works on a platform where `AGENTS.md` says otherwise
- disable the compatibility check to make an error go away without telling
  the user what the check found
- commit or push unless asked
