/// Device probing results and model compatibility reports.
library;

/// Hardware acceleration backends detected on this device.
enum Accelerator { cpu, gpu, nnapi, neuralEngine, metal }

/// Snapshot of device capabilities relevant to on-device inference.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.totalMemoryMB,
    required this.availableMemoryMB,
    required this.freeDiskMB,
    required this.platform,
    this.socModel,
    this.accelerators = const {Accelerator.cpu},
  });

  /// Total physical RAM.
  final int totalMemoryMB;

  /// Currently available RAM (best effort).
  final int availableMemoryMB;

  /// Free disk space on the data partition.
  final int freeDiskMB;

  /// `android` / `ios` / `macos` / ...
  final String platform;

  /// SoC marketing name when known.
  final String? socModel;

  /// Detected hardware accelerators (always contains [Accelerator.cpu]).
  final Set<Accelerator> accelerators;

  bool supports(Accelerator accelerator) => accelerators.contains(accelerator);
}

/// Result of checking a manifest against [DeviceCapabilities].
class CompatibilityReport {
  const CompatibilityReport({
    required this.isCompatible,
    required this.reasons,
    this.availableMemoryMB,
    this.requiredMemoryMB,
  });

  const CompatibilityReport.compatible()
      : isCompatible = true,
        reasons = const [],
        availableMemoryMB = null,
        requiredMemoryMB = null;

  final bool isCompatible;

  /// Human readable incompatibilities (empty when compatible).
  final List<String> reasons;

  final int? availableMemoryMB;
  final int? requiredMemoryMB;

  /// One-line summary for logs / error messages.
  String get summary =>
      isCompatible ? 'compatible' : reasons.join('; ');
}
