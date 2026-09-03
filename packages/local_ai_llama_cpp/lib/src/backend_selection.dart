/// Pure mapping from the core [RuntimePreference] to llama.cpp load
/// parameters (spec §2).
///
/// llama.cpp expresses "use the GPU" as *how many transformer layers to
/// offload* (`n_gpu_layers`), not as a delegate enum, and the GPU backend
/// itself (Metal / Vulkan / CUDA) is chosen when the shared library is
/// built, not at load time. So the only runtime decision is the offload
/// count plus the CPU thread count.
library;

import 'package:local_ai_core/local_ai_core.dart';

/// llama.cpp load parameters derived from a [RuntimePreference].
class BackendPlan {
  const BackendPlan({
    required this.gpuLayers,
    required this.threads,
    required this.preference,
  });

  /// Value for `ModelParams.nGpuLayers`. `0` keeps everything on the CPU;
  /// [maxOffloadLayers] means "offload as much as the build supports".
  final int gpuLayers;

  /// Value for `ContextParams.nThreads` / `nThreadsBatch`.
  final int threads;

  /// The preference this plan was derived from.
  final RuntimePreference preference;

  /// Whether this plan asks llama.cpp for any GPU offload at all.
  bool get usesGpu => gpuLayers > 0;

  /// The CPU-only variant of this plan, used for the adapter-internal retry
  /// after a GPU init failure (spec §2, fallback layer 1).
  BackendPlan get cpuFallback => BackendPlan(
        gpuLayers: 0,
        threads: threads,
        preference: RuntimePreference.cpu,
      );

  @override
  String toString() =>
      'BackendPlan(gpuLayers: $gpuLayers, threads: $threads, '
      'preference: ${preference.name})';
}

/// Chooses llama.cpp load parameters for a [RuntimePreference].
abstract final class BackendSelection {
  /// "Offload everything" sentinel; llama.cpp clamps it to the real layer
  /// count and silently keeps layers on the CPU when VRAM runs out.
  static const int maxOffloadLayers = 999;

  /// Upper bound on inference threads. Beyond the physical big-core count
  /// llama.cpp loses throughput to scheduling overhead, and on phones it
  /// also fights the UI isolate for cores.
  static const int maxThreads = 8;

  /// Builds the plan for [preference].
  ///
  /// `npu` maps to the GPU plan: llama.cpp has no NPU backend, and the
  /// closest available accelerator is the GPU one the library was built
  /// with. `auto` also offloads — a CPU-only build reports zero offloadable
  /// layers and llama.cpp runs on the CPU anyway, and if GPU init does
  /// fail the adapter retries on CPU (and the kit's `RuntimeScheduler`
  /// retries again above that).
  static BackendPlan resolve(
    RuntimePreference preference, {
    int? processorCount,
  }) {
    final threads = threadsFor(processorCount);
    final gpuLayers = switch (preference) {
      RuntimePreference.cpu => 0,
      RuntimePreference.gpu ||
      RuntimePreference.npu ||
      RuntimePreference.auto =>
        maxOffloadLayers,
    };
    return BackendPlan(
      gpuLayers: gpuLayers,
      threads: threads,
      preference: preference,
    );
  }

  /// Thread count for [processorCount] cores: half the cores (leaving room
  /// for the UI isolate and the OS), at least 2 and at most [maxThreads].
  static int threadsFor(int? processorCount) {
    final cores = (processorCount ?? 4) <= 0 ? 4 : processorCount ?? 4;
    return (cores ~/ 2).clamp(2, maxThreads);
  }
}
