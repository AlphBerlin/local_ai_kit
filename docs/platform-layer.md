# Platform Layer (`local_ai_flutter`)

`local_ai_flutter` is the only package allowed to touch Flutter platform plugins (see [Adapters](adapters.md)). Besides `FlutterStoragePaths` (covered in [Storage Layout](storage.md)), it ships six platform primitives that `local_ai_kit` and the adapters build on. None of these are wired to `LocalAI.initialize`'s public parameters except indirectly — they're constructed internally, and most are only interesting when you're debugging a platform-specific issue or writing a custom adapter.

## PermissionGate

Thin wrapper over `permission_handler`, used for microphone access:

```dart
final gate = PermissionGate();
await gate.ensureMicrophone(); // throws InvalidStateError if denied
final granted = await gate.hasMicrophone();
await gate.openSettings();     // deep-links to system settings
```

`FlutterAudioRecorder` calls `ensureMicrophone()` itself the first time `start()` is used if the `record` plugin reports no permission yet, so most apps never call this directly — it's exposed for apps that want to request permission proactively (e.g. before showing a "grant mic access" screen).

## AppLifecycleObserver

Wraps `WidgetsBindingObserver` and collapses Flutter's five `AppLifecycleState` values down to two:

| `AppLifecycleState` | `AppLifecyclePhase` |
|---|---|
| `resumed` | `foreground` |
| `paused`, `inactive`, `hidden`, `detached` | `background` |

`RuntimeScheduler` subscribes to `phases` and unloads every unlocked model on a `background` transition when `RuntimeMemoryPolicy.trimOnBackground` is true (see [Runtime & Memory](runtime-memory.md)). Call `dispose()` to detach the observer.

## FlutterAudioRecorder

`LocalAudioSource` backed by the `record` plugin. Captures PCM16 and converts to `Float32List` samples in `[-1, 1]` at the recorder boundary, so VAD/STT code never deals with integer encodings.

**Known gap:** every emitted `AudioFrame` is tagged `format: AudioFormat.pcm16kMono` regardless of the `format` argument passed to `start()` — if you ever call `start(format: someOtherFormat)`, the frame metadata will be wrong even though the underlying capture uses the requested sample rate/channels. In practice this hasn't mattered because every current caller uses the default `pcm16kMono`.

## FlutterAudioPlayer

`LocalAudioOutput` backed by `audioplayers`. Because `audioplayers` is file/bytes-oriented rather than sample-stream-oriented, playback isn't truly low-latency streaming today: the whole `Stream<AudioChunk>` is buffered into a growing in-memory WAV, written once to `cacheDir`, and then played back as a file — `/usr/bin/afplay` on macOS, `audioplayers`' `DeviceFileSource` elsewhere. `stop()` kills the active process/player immediately, which is what makes barge-in's playback cutoff work. The source has an explicit `TODO(verify)` calling out that a PCM push API (platform channel or a streaming plugin) should replace this before a low-latency release; the public `play`/`stop` contract wouldn't change.

## FlutterNetworkPolicy

Wraps `connectivity_plus`, mapping its results onto `NetworkStatus.wifi` / `.cellular` / `.offline` / `.unknown`. `canDownload(wifiOnly: true)` fails **open** (returns `true`) on `unknown` status (e.g. desktop platforms, or missing permission) — on those platforms a real network failure surfaces later from the download itself rather than being pre-blocked here.

## FlutterDeviceProbe

Backs `ai.runtime.deviceCapabilities()` / `checkCompatibility()` (see [Runtime & Memory](runtime-memory.md)). **Currently a placeholder, not a real probe:** on both Android and iOS it hardcodes `totalMemoryMB: 4096`, `availableMemoryMB: 2048`, and `freeDiskMB` to 100 GB, regardless of the actual device — the source has multiple `TODO(verify)` comments noting that `device_info_plus` doesn't expose RAM directly and that `dart:io` has no free-space API, so these are conservative stand-ins pending a real platform-channel probe. This means memory/disk pre-flight checks (model compatibility gating, download disk checks) don't yet reflect the real device — see the [FAQ](faq.md#what-happens-when-the-device-runs-out-of-ram) for the practical implication.

Inject your own probe via `LocalAI.initialize(deviceProbe: () async => myRealCapabilities)` if you need accurate figures before this is fixed upstream.
