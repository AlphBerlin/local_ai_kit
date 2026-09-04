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
    this.acceleratorsKnown = true,
  });

  /// Nothing could be probed.
  ///
  /// Every metric reads `0` and [acceleratorsKnown] is `false`, so a
  /// compatibility check against this reports each affected check as
  /// *unknown* rather than silently passing it — or, worse, reading the
  /// `{cpu}` default as a positive finding that the device has no GPU.
  const DeviceCapabilities.unknown()
      : totalMemoryMB = 0,
        availableMemoryMB = 0,
        freeDiskMB = 0,
        platform = 'unknown',
        socModel = null,
        accelerators = const {Accelerator.cpu},
        acceleratorsKnown = false;

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
  ///
  /// Only meaningful when [acceleratorsKnown] is `true`.
  final Set<Accelerator> accelerators;

  /// Whether [accelerators] is a real probe result.
  ///
  /// `false` means the probe failed or never ran, so the `{cpu}` default
  /// is a placeholder, not a finding. A checker must not conclude "this
  /// device has no GPU" from it.
  final bool acceleratorsKnown;

  bool supports(Accelerator accelerator) => accelerators.contains(accelerator);
}

/// Result of checking a manifest against [DeviceCapabilities].
///
/// Produced by `ModelCompatibilityChecker.check`. [isCompatible] answers
/// only the blocking question — a compatible report can still carry
/// [warnings] worth showing the user (tight RAM, CPU-only fallback, a
/// clamped context window).
class CompatibilityReport {
  const CompatibilityReport({
    required this.isCompatible,
    required this.reasons,
    this.availableMemoryMB,
    this.requiredMemoryMB,
    this.issues = const [],
  });

  const CompatibilityReport.compatible()
      : isCompatible = true,
        reasons = const [],
        availableMemoryMB = null,
        requiredMemoryMB = null,
        issues = const [];

  /// Folds [issues] into a report: any blocking issue makes it
  /// incompatible, and [reasons] carries the blocking messages so older
  /// call sites keep working unchanged.
  factory CompatibilityReport.fromIssues(
    List<CompatibilityIssue> issues, {
    int? availableMemoryMB,
    int? requiredMemoryMB,
  }) {
    final blockers = issues.where((i) => i.isBlocking).toList(growable: false);
    return CompatibilityReport(
      isCompatible: blockers.isEmpty,
      reasons: blockers.map((i) => i.message).toList(growable: false),
      availableMemoryMB: availableMemoryMB,
      requiredMemoryMB: requiredMemoryMB,
      issues: List.unmodifiable(issues),
    );
  }

  final bool isCompatible;

  /// Human readable incompatibilities (empty when compatible).
  ///
  /// Equivalent to the messages of the blocking [issues].
  final List<String> reasons;

  final int? availableMemoryMB;
  final int? requiredMemoryMB;

  /// Every finding, blocking and non-blocking.
  final List<CompatibilityIssue> issues;

  /// Findings that prevent the model from running here.
  List<CompatibilityIssue> get blockers =>
      issues.where((i) => i.isBlocking).toList(growable: false);

  /// Findings that only degrade the experience.
  List<CompatibilityIssue> get warnings =>
      issues.where((i) => !i.isBlocking).toList(growable: false);

  bool get hasWarnings => issues.any((i) => !i.isBlocking);

  /// One-line summary for logs / error messages.
  String get summary {
    if (!isCompatible) return reasons.join('; ');
    if (hasWarnings) {
      return 'compatible with warnings: '
          '${warnings.map((i) => i.message).join('; ')}';
    }
    return 'compatible';
  }

  @override
  String toString() => 'CompatibilityReport($summary)';
}

/// Which property a [CompatibilityIssue] is about.
enum CompatibilityCheck {
  /// `manifest.platforms` versus `DeviceCapabilities.platform`.
  platform,

  /// `manifest.minMemoryMB` versus total physical RAM.
  totalMemory,

  /// `manifest.minMemoryMB` versus RAM free right now.
  availableMemory,

  /// Download + install size versus free disk.
  disk,

  /// `manifest.requiredAccelerators` versus detected accelerators.
  accelerator,

  /// Requested context window versus `manifest.contextLength`.
  contextWindow,

  /// A metric needed for a check was not available on this device.
  unknown,
}

/// How much a [CompatibilityIssue] matters.
enum CompatibilitySeverity {
  /// The model cannot run here. Downloading it wastes the user's bytes.
  blocking,

  /// The model should run, but degraded — slower backend, tight RAM, a
  /// truncated context window.
  warning,
}

/// One finding produced by [ModelCompatibilityChecker].
class CompatibilityIssue {
  const CompatibilityIssue({
    required this.check,
    required this.severity,
    required this.message,
    this.requiredMB,
    this.availableMB,
  });

  final CompatibilityCheck check;
  final CompatibilitySeverity severity;

  /// Human readable, safe to show in UI and logs.
  final String message;

  /// What the model needs, when the check is a capacity check.
  final int? requiredMB;

  /// What the device has, when the check is a capacity check.
  final int? availableMB;

  bool get isBlocking => severity == CompatibilitySeverity.blocking;

  @override
  String toString() => '${severity.name}(${check.name}): $message';
}
