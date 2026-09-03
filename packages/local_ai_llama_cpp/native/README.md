# Native llama.cpp library

`llama_cpp_dart` is **bindings only**. Its pubspec declares no
`flutter: plugin:` section, so nothing in that package's `android/`, `ios/`,
`macos/`, `linux/` or `windows/` directories is wired into a Flutter build —
Flutter never runs its podspecs or Gradle files, and the `Llama.xcframework`
it ships in `dist/` is not vendored into your app either. Getting a llama.cpp
binary onto the device is therefore this package's job (and yours), which is
what the scripts here are for.

## Building

```sh
./build_llama.sh linux                    # Vulkan
./build_llama.sh macos                    # Metal
./build_llama.sh ios                      # Metal, xcframework
ANDROID_NDK_HOME=… ./build_llama.sh android --backend vulkan
./build_llama.ps1 -Backend vulkan         # Windows (PowerShell)
```

Options: `--ref <git-ref>` (or `$LLAMA_CPP_REF`) picks the llama.cpp
revision, `--backend cpu|vulkan|opencl|metal|cuda` overrides the default
backend, `--out <dir>` the output directory, `--abis "arm64-v8a x86_64"` the
Android ABIs.

**Pin the revision.** The default is `master`, which is only right while you
are actively tracking upstream. `llama_cpp_dart`'s bindings are generated
against one llama.cpp revision; a much newer one can change the C API those
bindings call, and the failure mode is a crash at the first FFI call, not a
build error. Pin `LLAMA_CPP_REF` to the revision matching your installed
`llama_cpp_dart` version and bump both together.

Both scripts build llama.cpp's `mtmd` target (`LLAMA_BUILD_TOOLS=ON`) rather
than `llama` alone: `mtmd` re-exports the entire llama API, its name is what
`LlamaCppRuntime.defaultLibraryName` resolves to, and it leaves the door open
for multimodal GGUF models later. Nothing in this adapter calls an `mtmd_*`
symbol today — the generated bindings look symbols up lazily, so the unused
ones are never resolved.

## Where the artifacts go

| Platform | Artifact | Placement |
|---|---|---|
| Android | `libmtmd.so`, `libllama.so`, `libggml*.so` per ABI | `android/app/src/main/jniLibs/<abi>/` |
| iOS | `llama.xcframework` (static) | Link into the app target; symbols then resolve from the process, which is why `defaultLibraryName` returns `null` on iOS |
| macOS | `libmtmd.dylib` + `libggml*.dylib` | Bundle in `Contents/Frameworks/`, or pass an absolute path to `LlamaCppRuntime.useLibrary` |
| Windows | `mtmd.dll`, `llama.dll`, `ggml*.dll` | Next to the app `.exe` |
| Linux | `libmtmd.so` + `libggml*.so` | Next to the app binary, or on `LD_LIBRARY_PATH` |

If your app ships the library somewhere else, say so before the first
`load()`:

```dart
LlamaCppRuntime.useLibrary('/absolute/path/to/libmtmd.so');
LlamaCppRuntime.useLibrary(null); // resolve from the process (static link)
```

## Status

These scripts are developer tooling: they are **not** run by this repo's CI,
and no prebuilt binary ships with the package. They encode the flags each
platform needs, but each platform's toolchain (NDK, Xcode, Vulkan SDK, MSVC)
still has to be present, and none of the five targets has been exercised
here. Treat a first run on a new platform as something to debug, not as a
one-command install. A CI matrix that actually produces and publishes these
libraries is the obvious next step and does not exist yet.

Do not commit `native/llama.cpp/` (the clone) or `native/build/` — both are
generated; the repo's `.gitignore` covers them.
