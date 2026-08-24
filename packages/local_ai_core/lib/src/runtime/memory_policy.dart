/// Runtime backend preference and memory management policy.
library;

/// Preferred execution backend for inference.
enum RuntimePreference {
  /// Let the adapter pick the best available backend.
  auto,

  /// CPU only (most compatible, slowest).
  cpu,

  /// GPU delegate (OpenCL / Metal).
  gpu,

  /// NPU / NNAPI / Neural Engine.
  npu,
}

/// Memory management policy for the runtime scheduler (architecture §5.2).
class RuntimeMemoryPolicy {
  const RuntimeMemoryPolicy({
    this.unloadUnusedAfter = const Duration(minutes: 5),
    this.maxLoadedModels = 2,
    this.trimOnBackground = true,
  });

  /// Conservative preset for low-RAM devices.
  const RuntimeMemoryPolicy.lowMemory()
      : unloadUnusedAfter = const Duration(minutes: 2),
        maxLoadedModels = 1,
        trimOnBackground = true;

  /// Models idle longer than this are unloaded by the periodic sweep.
  final Duration unloadUnusedAfter;

  /// Loading a model beyond this count evicts the least-recently-used
  /// unlocked model first.
  final int maxLoadedModels;

  /// When the app goes to background, unload all unlocked models.
  final bool trimOnBackground;
}

/// Live memory accounting reported by the runtime.
class MemoryUsage {
  const MemoryUsage({
    required this.totalBytes,
    required this.usedBytes,
    required this.modelBytes,
  });

  /// Total physical memory.
  final int totalBytes;

  /// Currently used memory (process or system, implementation defined).
  final int usedBytes;

  /// Estimated bytes held by loaded models.
  final int modelBytes;

  double get usedFraction => totalBytes > 0 ? usedBytes / totalBytes : 0;
}
