# Platform setup

Per-platform files to change before the first run. Every entry below is
mirrored in `examples/demo/`, which is the reference to check against when
something here looks stale.

## All platforms

Models are downloaded at runtime, so **every** platform needs network access,
even a "fully offline" app — offline means inference is local, not that the
weights arrive by magic.

## Android

`android/app/src/main/AndroidManifest.xml`, inside `<manifest>` and outside
`<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<!-- Microphone capture (STT / VAD / voice sessions) only: -->
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

`android/app/build.gradle.kts` — the demo uses the Flutter defaults:

```kotlin
android {
    ndkVersion = flutter.ndkVersion
    defaultConfig {
        minSdk = flutter.minSdkVersion
    }
}
```

If a build fails on `minSdk`, raise it to what the failing plugin asks for
rather than guessing a number: the error names it. The transitive plugins
that tend to set the floor are `flutter_gemma`, `sherpa_onnx`, `record` and
`permission_handler`.

Runtime permission for the microphone is requested by
`FlutterAudioRecorder.start()` on first use, so most apps never call
`PermissionGate.ensureMicrophone()` themselves — expose it only if you want a
"grant mic access" screen before recording starts.

## iOS

`ios/Runner/Info.plist`, only when the app records audio:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Explain here, in the user's words, what the microphone is for.</string>
```

App Store review rejects a placeholder string. Write the real reason.

No entry is needed for network access on iOS.

## macOS

`macos/Runner/Info.plist`, when recording audio:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Explain here what the microphone is for.</string>
```

macOS is sandboxed, so entitlements matter too. In **both**
`macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

Release is the one people forget; a build that records fine in debug and
silently fails when shipped is almost always a missing Release entitlement.

## Windows and Linux

No manifest changes. Two things to know instead:

- Most catalog manifests list `['android', 'ios', 'macos']`, so the
  compatibility checker reports them incompatible here. That is accurate, not
  a bug: those models have no Windows/Linux runtime path. The GGUF models
  served by `local_ai_llama_cpp` do list desktop platforms.
- `FlutterNetworkPolicy.canDownload` fails **open** on `NetworkStatus.unknown`,
  which is what desktop reports; a real network failure then surfaces from the
  download itself rather than being pre-blocked. Note that the same fail-open
  path is reachable on mobile — `_map` sends Android `vpn` and iOS `other`
  (which is what iOS reports for *any* active VPN) to `unknown` too, so a
  cellular download behind a VPN can slip past `DownloadPolicy.wifiOnly`. See
  `references/troubleshooting.md`.

## llama.cpp native library

`local_ai_llama_cpp` depends on `llama_cpp_dart`, which is bindings-only —
there is no Flutter plugin wiring, so nothing bundles the native library for
you. Either:

1. build and bundle it per platform (`packages/local_ai_llama_cpp/native/build_llama.sh`,
   documented in `packages/local_ai_llama_cpp/native/README.md`), or
2. point the runtime at an existing library with
   `LlamaCppRuntime.useLibrary(path)`.

Read that README before promising a user this adapter works on their target
platform. It is the single most common reason a llama.cpp integration fails
at runtime after a clean build.

## Verifying

```sh
flutter pub get
flutter analyze
flutter build apk --debug        # or: ios / macos / windows / linux
```

A build is the real check for platform config; `analyze` does not read
manifests or entitlements.
