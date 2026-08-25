# Verification Marker Completion Design

**Date:** 2026-08-25

**Status:** Approved in chat; implementation pending written-plan review.

## Goal

Replace the maintained repository's verification placeholders with tested,
supported implementations while preserving the public LocalAI Kit contracts
and excluding Flutter-generated application-template comments from product
code changes.

## Scope

The maintained markers are concentrated in four areas:

1. `local_ai_flutter` device probing currently returns fixed mobile RAM values
   and a fixed disk value.
2. `local_ai_flutter` buffers the complete TTS stream into a WAV because
   `audioplayers` has no PCM push stream.
3. `local_ai_gemma` uses dynamic fields around a now-pinned, typed
   `flutter_gemma` 1.6.5 API.
4. `local_ai_genkit` documents a model-provider registration sketch even
   though its `genkit` 0.5 dependency is a client-only API.

The Android application-ID/signing comments and Linux/Windows Flutter
ephemeral CMake comments are generated-template guidance. They require an
application owner's identity or Flutter tooling changes and are not LocalAI
Kit implementation work, so they remain unchanged.

## Design

### Device capabilities

`FlutterDeviceProbe` will keep its one-shot cache and public return type. Its
default source will:

- use `AndroidDeviceInfo.physicalRamSize`, `availableRamSize`, and
  `freeDiskSize` on Android;
- use the equivalent `IosDeviceInfo` fields on iOS;
- read total/available memory and free space from the host operating system on
  macOS, Linux, and Windows;
- return zero for metrics that the running platform cannot provide, rather
  than inventing capacity that could incorrectly approve a model download.

The source will be injectable so parser and fallback behavior can be tested
without depending on a physical device. Desktop commands will be invoked
without a shell and parsed defensively. Platform accelerators and SoC labels
will retain their current semantics.

### PCM playback

`FlutterAudioPlayer` will retain `LocalAudioOutput.play(Stream<AudioChunk>)`
and `stop()` semantics. The implementation will use `flutter_soloud`'s
PCM `setBufferStream`/`addAudioDataStream` APIs:

- initialize the singleton engine once with low-latency output;
- create a released PCM stream from the first non-empty chunk's format;
- feed converted signed-16 PCM as chunks arrive;
- mark the stream ended on normal completion;
- stop the active sound handle and dispose the source on barge-in or error.

The old `cacheDir` constructor parameter remains accepted for source
compatibility but is no longer used for playback scratch files. Pure PCM
conversion stays in a small testable helper. The new backend supports the
platforms supported by the selected plugin and removes the complete-stream
memory growth of the old implementation.

### Gemma boundary

The adapter's native boundary will use `fg.InferenceModel` and
`fg.InferenceChat` rather than `dynamic`. Generation will consume the typed
`fg.ModelResponse` hierarchy and emit only `fg.TextResponse` tokens. Model
creation, session creation, and close helpers will carry the concrete types,
so compiler errors identify future upstream API drift at the boundary.

### Genkit model registration

The dependency will move to the verified Genkit Dart framework range
`>=0.14.1 <0.15.0`, whose `Genkit` class exposes `defineModel`. The adapter
will provide a real registration method accepting a caller-owned `Genkit`
instance and model name. It will map:

- core `LlmMessage` values to Genkit text messages;
- Genkit `ModelRequest` values back to core `LlmRequest`;
- streamed core chunks through Genkit's `sendChunk` callback;
- the final core response to a Genkit `ModelResponse`.

The adapter will not create a hidden global Genkit instance. Existing
self-contained flow/tool orchestration remains available independently of
the optional native Genkit registration.

### Documentation

Platform-layer, FAQ, and Genkit documentation will describe the implemented
behavior, plugin requirements, and the intentional generated-template
exclusion. No maintained source or documentation will retain a verification
marker for these completed areas.

## Error handling

- Device probe command failures produce zero for the affected metric and do
  not prevent the remaining capability fields from being returned.
- PCM stream failures stop and dispose the active backend before rethrowing;
  explicit `stop()` remains idempotent.
- Gemma keeps its existing native runtime error translation and GPU-to-CPU
  fallback behavior.
- Genkit mapping rejects unsupported non-text parts with a clear error rather
  than silently dropping content.

## Testing

- Device source tests cover Android/iOS field mapping through fakes, Linux and
  macOS parser fixtures, Windows parser fixtures, cache reuse, and zero-value
  fallback.
- PCM helper tests cover clipping, signed-16 conversion, and empty chunks; a
  fake playback backend verifies stream forwarding and stop behavior.
- Gemma tests cover typed model-file selection and the response-token mapping
  boundary without requiring a native model.
- Genkit tests cover registration, unary generation, streaming callbacks,
  system/user/assistant message mapping, and unsupported content errors.
- The final verification will include format, analysis, core tests, Flutter
  tests, and the repository's bundle policy check. If the Flutter SDK cache
  is still protected in the execution environment, that limitation will be
  reported with the exact command output.

## Commit sequence

1. `feat(flutter): probe real device memory and disk`
2. `feat(flutter): stream PCM audio through SoLoud`
3. `refactor(gemma): type flutter_gemma runtime boundary`
4. `feat(genkit): register local model with Genkit`
5. `docs: document completed platform integrations`
