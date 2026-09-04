/// Where the llama.cpp shared library comes from.
///
/// `llama_cpp_dart` ships Dart FFI bindings only — the native library is
/// built and bundled per platform by `native/build_llama.sh` (see
/// `native/README.md`). This file is the single place that decides which
/// library name to hand `DynamicLibrary.open`, and the escape hatch an app
/// uses when it ships the library somewhere else.
library;

import 'dart:io';

/// Global llama.cpp runtime configuration.
abstract final class LlamaCppRuntime {
  static String? _libraryPathOverride;
  static bool _libraryPathOverridden = false;

  /// Overrides the shared-library path for every adapter in this process.
  ///
  /// Pass an absolute path (or a name resolvable by the platform loader).
  /// Pass `null` to force "resolve symbols from the running process", which
  /// is what a statically linked iOS/macOS build needs. Must be called
  /// before the first `load()`; the library is opened once per isolate.
  static void useLibrary(String? path) {
    _libraryPathOverride = path;
    _libraryPathOverridden = true;
  }

  /// Clears an override set by [useLibrary].
  static void useDefaultLibrary() {
    _libraryPathOverride = null;
    _libraryPathOverridden = false;
  }

  /// The library path handed to the worker isolate for the current platform.
  static String? get libraryPath => _libraryPathOverridden
      ? _libraryPathOverride
      : defaultLibraryName(Platform.operatingSystem);

  /// Whether an app-supplied override is active.
  static bool get hasOverride => _libraryPathOverridden;

  /// Default library name for [operatingSystem], or `null` when symbols are
  /// expected to be linked into the process itself.
  ///
  /// The bundled library is llama.cpp's `mtmd` build, which re-exports the
  /// whole `llama` API; iOS and macOS link it statically into the app
  /// binary (a dynamic library inside an app bundle needs code-signing
  /// gymnastics that a static link avoids), so there they resolve from the
  /// process.
  static String? defaultLibraryName(String operatingSystem) =>
      switch (operatingSystem) {
        'android' => 'libmtmd.so',
        'linux' => 'libmtmd.so',
        'windows' => 'mtmd.dll',
        'macos' => _resolveMacosLibrary(),
        'ios' => null,
        _ => null,
      };

  static String? _resolveMacosLibrary() {
    // 1. Explicit environment variable
    final envPath = Platform.environment['LLAMA_CPP_LIB_PATH'];
    if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
      return envPath;
    }

    // 2. App bundle Frameworks directory (e.g. Flutter macOS app)
    try {
      final exe = File(Platform.resolvedExecutable);
      final frameworks = Directory('${exe.parent.parent.path}/Frameworks');
      if (frameworks.existsSync()) {
        final mtmd = File('${frameworks.path}/libmtmd.dylib');
        if (mtmd.existsSync()) return mtmd.path;
        final llama = File('${frameworks.path}/libllama.dylib');
        if (llama.existsSync()) return llama.path;
      }
    } catch (_) {}

    // 3. Prebuilt binaries shipped with llama_cpp_dart in pub-cache
    try {
      final home = Platform.environment['HOME'];
      final pubCache = Platform.environment['PUB_CACHE'] ??
          (home != null ? '$home/.pub-cache' : null);
      if (pubCache != null) {
        final hostedDir = Directory('$pubCache/hosted/pub.dev');
        if (hostedDir.existsSync()) {
          final entries = hostedDir
              .listSync()
              .whereType<Directory>()
              .where((d) => d.path.contains('llama_cpp_dart'))
              .toList();
          for (final entry in entries) {
            final mtmd = File('${entry.path}/bin/MAC_ARM64/libmtmd.dylib');
            if (mtmd.existsSync()) return mtmd.path;
            final llama = File('${entry.path}/bin/MAC_ARM64/libllama.dylib');
            if (llama.existsSync()) return llama.path;
          }
        }
      }
    } catch (_) {}

    // 4. Common Homebrew or system installs
    for (final candidate in [
      '/opt/homebrew/lib/libllama.dylib',
      '/usr/local/lib/libllama.dylib',
    ]) {
      try {
        if (File(candidate).existsSync()) return candidate;
      } catch (_) {}
    }

    return 'libmtmd.dylib';
  }
}
