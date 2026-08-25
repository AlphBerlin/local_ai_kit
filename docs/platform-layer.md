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

`LocalAudioOutput` backed by `flutter_soloud`. Each `AudioChunk` is converted to little-endian PCM16 and pushed into a native `setBufferStream` with released buffering and a bounded two-second buffer, so playback starts while synthesis is still producing audio instead of waiting for a complete WAV file. `stop()` cancels the input iterator, stops the active voice and disposes its source for barge-in. The `cacheDir` constructor argument remains for source compatibility, but no playback scratch files are created.

## FlutterNetworkPolicy

Wraps `connectivity_plus`, mapping its results onto `NetworkStatus.wifi` / `.cellular` / `.offline` / `.unknown`. `canDownload(wifiOnly: true)` fails **open** (returns `true`) on `unknown` status (e.g. desktop platforms, or missing permission) — on those platforms a real network failure surfaces later from the download itself rather than being pre-blocked here.

## FlutterDeviceProbe

Backs `ai.runtime.deviceCapabilities()` / `checkCompatibility()` (see [Runtime & Memory](runtime-memory.md)). On Android and iOS it reads physical RAM, available RAM and free disk from `device_info_plus`. On Linux it parses `/proc/meminfo` and `df`; on macOS it uses `sysctl`, `vm_stat` and `df`; on Windows it uses PowerShell CIM queries. A failed or unsupported metric is reported as `0` rather than a fabricated capacity. Pass a custom `DeviceMetricsSource` to `FlutterDeviceProbe` in tests or when an app has a more appropriate platform-specific source.
