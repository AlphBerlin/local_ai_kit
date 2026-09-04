/// Pre-flight model/device compatibility checking.
///
/// Answers "can this device run this model?" *before* a multi-gigabyte
/// download starts, and again before the runtime tries to load it. Pure
/// Dart and side-effect free: it takes a [LocalModelManifest] plus a
/// [DeviceCapabilities] snapshot and returns a [CompatibilityReport].
///
/// The checker never guesses when a metric is missing. Every probe value
/// that is `0` (unknown / unsupported platform, see `DeviceMetricsSource`)
/// makes the corresponding check report [CompatibilityCheck.unknown]
/// instead of a pass or a fail, so an unprobed desktop is never blocked by
/// a fabricated capacity.
library;

import 'device_capabilities.dart';
import 'manifest.dart';

export 'device_capabilities.dart'
    show CompatibilityCheck, CompatibilityIssue, CompatibilitySeverity;

/// Tunables for [ModelCompatibilityChecker].
class ModelCompatibilityPolicy {
  const ModelCompatibilityPolicy({
    this.memoryHeadroomFactor = 1.25,
    this.diskHeadroomFactor = 1.2,
    this.requireAvailableMemory = false,
    this.estimateMemoryFromFileSize = true,
  });

  /// Strict preset: a transient RAM shortfall also blocks. Use on devices
  /// where a failed native load takes the whole app down instead of
  /// throwing.
  const ModelCompatibilityPolicy.strict()
      : memoryHeadroomFactor = 1.4,
        diskHeadroomFactor = 1.3,
        requireAvailableMemory = true,
        estimateMemoryFromFileSize = true;

  /// Permissive preset: capacity shortfalls are warnings, only platform
  /// and required accelerators block.
  const ModelCompatibilityPolicy.permissive()
      : memoryHeadroomFactor = 1.0,
        diskHeadroomFactor = 1.05,
        requireAvailableMemory = false,
        estimateMemoryFromFileSize = false;

  /// RAM the model needs beyond `minMemoryMB` before the checker stops
  /// warning about a tight fit (KV cache, tokenizer, framework overhead).
  final double memoryHeadroomFactor;

  /// Disk multiplier applied to the download size. Matches the
  /// `DownloadManager` pre-flight, which needs room for the `.part` files
  /// and the installed copy at the same time.
  final double diskHeadroomFactor;

  /// Treat "not enough free RAM *right now*" as blocking rather than as a
  /// warning. Off by default: available RAM is transient and the runtime
  /// scheduler can free some by evicting another model.
  final bool requireAvailableMemory;

  /// When a manifest leaves `minMemoryMB` at its `0` default, derive an
  /// estimate from the weight file size instead of skipping the RAM checks
  /// entirely. Estimates only ever produce warnings, never blockers.
  final bool estimateMemoryFromFileSize;
}

/// Which gate a compatibility check is running for.
///
/// The two gates ask different questions. Before a **download** the free
/// disk needed to fetch and install the files matters. Before a **load**
/// those files are already installed, so re-applying the download's disk
/// requirement would refuse to load a model that is sitting on disk and
/// perfectly usable, merely because the device has since filled up.
enum CompatibilityStage {
  /// Runs every check, including the download + install disk requirement.
  download,

  /// Skips the disk check; the files are already installed.
  load,
}

/// How the kit reacts to a failed compatibility check.
enum CompatibilityEnforcement {
  /// Never check. Downloads and loads proceed exactly as before.
  off,

  /// Check and report through events/reports, but never fail a call.
  warn,

  /// Throw [IncompatibleDeviceError] on a blocking issue, before the
  /// download starts and before the runtime loads the model.
  enforce,
}

/// Checks a [LocalModelManifest] against a [DeviceCapabilities] snapshot.
///
/// ```dart
/// final report = ModelCompatibilityChecker.check(
///   manifest: manifest,
///   device: await ai.runtime.deviceCapabilities(),
/// );
/// if (!report.isCompatible) showBlockedDialog(report.summary);
/// ```
abstract final class ModelCompatibilityChecker {
  /// Fixed runtime overhead assumed on top of the weights when estimating
  /// RAM from file size: tokenizer, framework, and a small KV cache.
  static const int estimatedOverheadMB = 256;

  /// Multiplier applied to the on-disk weight size when estimating the
  /// resident set of a loaded model.
  static const double estimatedWeightsFactor = 1.15;

  /// Rough RAM requirement derived from [manifest]'s file sizes, used only
  /// when the manifest does not declare `minMemoryMB`.
  ///
  /// Deliberately crude — quantized weights are mostly mapped as-is, so
  /// "weights + 15% + 256MB" tracks reality closely enough to warn on a
  /// 4GB phone being offered a 3GB model. Never used to block.
  static int estimateRequiredMemoryMB(LocalModelManifest manifest) {
    if (manifest.totalSizeMB <= 0) return 0;
    return (manifest.totalSizeMB * estimatedWeightsFactor).ceil() +
        estimatedOverheadMB;
  }

  /// Disk needed to download *and* install [manifest], including headroom.
  static int requiredDiskMB(
    LocalModelManifest manifest, {
    ModelCompatibilityPolicy policy = const ModelCompatibilityPolicy(),
  }) =>
      (manifest.totalSizeMB * policy.diskHeadroomFactor).ceil();

  /// Runs every check and folds the findings into one report.
  ///
  /// [requestedContextTokens] is the app's configured context window (e.g.
  /// `LlmConfig.maxContextTokens`); pass it to have the checker warn when
  /// the model cannot serve it.
  ///
  /// [stage] selects which gate this is: [CompatibilityStage.download]
  /// (the default) includes the disk requirement, [CompatibilityStage.load]
  /// omits it because the files are already installed.
  static CompatibilityReport check({
    required LocalModelManifest manifest,
    required DeviceCapabilities device,
    ModelCompatibilityPolicy policy = const ModelCompatibilityPolicy(),
    int? requestedContextTokens,
    CompatibilityStage stage = CompatibilityStage.download,
  }) {
    final issues = <CompatibilityIssue>[];

    _checkPlatform(issues, manifest, device);
    final requiredMemoryMB = _checkMemory(issues, manifest, device, policy);
    if (stage == CompatibilityStage.download) {
      _checkDisk(issues, manifest, device, policy);
    }
    _checkAccelerators(issues, manifest, device);
    _checkContextWindow(issues, manifest, requestedContextTokens);

    return CompatibilityReport.fromIssues(
      issues,
      availableMemoryMB: device.totalMemoryMB > 0 ? device.totalMemoryMB : null,
      requiredMemoryMB: requiredMemoryMB > 0 ? requiredMemoryMB : null,
    );
  }

  // ---------------------------------------------------------------------------

  static void _checkPlatform(
    List<CompatibilityIssue> issues,
    LocalModelManifest manifest,
    DeviceCapabilities device,
  ) {
    if (manifest.platforms.isEmpty) return;
    if (device.platform.isEmpty || device.platform == 'unknown') {
      issues.add(const CompatibilityIssue(
        check: CompatibilityCheck.unknown,
        severity: CompatibilitySeverity.warning,
        message: 'Platform could not be detected; the platform check was '
            'skipped.',
      ));
      return;
    }
    if (!manifest.platforms.contains(device.platform)) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.platform,
        severity: CompatibilitySeverity.blocking,
        message: 'Model "${manifest.id}" does not support '
            '${device.platform} (supported: ${manifest.platforms.join(", ")}).',
      ));
    }
  }

  /// Returns the RAM figure the checks were run against (0 when unknown).
  static int _checkMemory(
    List<CompatibilityIssue> issues,
    LocalModelManifest manifest,
    DeviceCapabilities device,
    ModelCompatibilityPolicy policy,
  ) {
    final declared = manifest.minMemoryMB;
    final estimated = policy.estimateMemoryFromFileSize
        ? estimateRequiredMemoryMB(manifest)
        : 0;
    final required = declared > 0 ? declared : estimated;
    if (required <= 0) return 0;

    // An estimate is never allowed to block a download — it is a heuristic
    // over file sizes, not a measurement.
    final isEstimate = declared <= 0;
    final blockingSeverity = isEstimate
        ? CompatibilitySeverity.warning
        : CompatibilitySeverity.blocking;
    final source = isEstimate ? ' (estimated from download size)' : '';

    if (device.totalMemoryMB <= 0) {
      issues.add(const CompatibilityIssue(
        check: CompatibilityCheck.unknown,
        severity: CompatibilitySeverity.warning,
        message: 'Total RAM could not be probed; memory checks were skipped.',
      ));
      return required;
    }

    if (device.totalMemoryMB < required) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.totalMemory,
        severity: blockingSeverity,
        message: 'Model "${manifest.id}" needs about ${required}MB RAM$source '
            'but the device has ${device.totalMemoryMB}MB total.',
        requiredMB: required,
        availableMB: device.totalMemoryMB,
      ));
      // Total RAM already fails; an available-RAM message adds nothing.
      return required;
    }

    if (device.availableMemoryMB <= 0) return required;

    final withHeadroom = (required * policy.memoryHeadroomFactor).ceil();
    if (device.availableMemoryMB < required) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.availableMemory,
        severity: policy.requireAvailableMemory && !isEstimate
            ? CompatibilitySeverity.blocking
            : CompatibilitySeverity.warning,
        message: 'Only ${device.availableMemoryMB}MB RAM is free right now; '
            '"${manifest.id}" needs about ${required}MB$source. Close other '
            'apps or unload another model first.',
        requiredMB: required,
        availableMB: device.availableMemoryMB,
      ));
    } else if (device.availableMemoryMB < withHeadroom) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.availableMemory,
        severity: CompatibilitySeverity.warning,
        message: 'RAM is tight: ${device.availableMemoryMB}MB free versus '
            '${withHeadroom}MB recommended for "${manifest.id}". Expect '
            'slower generation and possible evictions.',
        requiredMB: withHeadroom,
        availableMB: device.availableMemoryMB,
      ));
    }
    return required;
  }

  static void _checkDisk(
    List<CompatibilityIssue> issues,
    LocalModelManifest manifest,
    DeviceCapabilities device,
    ModelCompatibilityPolicy policy,
  ) {
    if (manifest.totalSizeMB <= 0) return;
    if (device.freeDiskMB <= 0) {
      issues.add(const CompatibilityIssue(
        check: CompatibilityCheck.unknown,
        severity: CompatibilitySeverity.warning,
        message: 'Free disk space could not be probed; the disk check was '
            'skipped.',
      ));
      return;
    }
    final needed = requiredDiskMB(manifest, policy: policy);
    if (device.freeDiskMB < needed) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.disk,
        severity: CompatibilitySeverity.blocking,
        message: 'Downloading "${manifest.id}" needs ${needed}MB free disk '
            '(${manifest.totalSizeMB}MB of files plus install headroom) but '
            'only ${device.freeDiskMB}MB is free.',
        requiredMB: needed,
        availableMB: device.freeDiskMB,
      ));
    }
  }

  static void _checkAccelerators(
    List<CompatibilityIssue> issues,
    LocalModelManifest manifest,
    DeviceCapabilities device,
  ) {
    // A required accelerator whose *name* this build does not recognise
    // always blocks: the manifest states a hard requirement we cannot even
    // evaluate, so we cannot claim the device meets it.
    for (final name in manifest.unknownRequiredAccelerators) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.accelerator,
        severity: CompatibilitySeverity.blocking,
        message: 'Model "${manifest.id}" requires the "$name" backend, which '
            'this version of the kit does not know about. Upgrade the kit, or '
            'pick a model this build can evaluate.',
      ));
    }

    if (manifest.requiredAccelerators.isEmpty &&
        manifest.preferredAccelerators.isEmpty) {
      return;
    }

    if (!device.acceleratorsKnown) {
      // The probe never ran or failed, so the `{cpu}` default is a
      // placeholder. Reading it as "this device has no GPU" would block a
      // capable device over a transient probe error.
      issues.add(const CompatibilityIssue(
        check: CompatibilityCheck.unknown,
        severity: CompatibilitySeverity.warning,
        message: 'Hardware accelerators could not be probed; the accelerator '
            'check was skipped.',
      ));
      return;
    }

    for (final accelerator in manifest.requiredAccelerators) {
      if (!device.supports(accelerator)) {
        issues.add(CompatibilityIssue(
          check: CompatibilityCheck.accelerator,
          severity: CompatibilitySeverity.blocking,
          message: 'Model "${manifest.id}" requires the '
              '${accelerator.name} backend, which this device does not '
              'expose.',
        ));
      }
    }
    if (manifest.preferredAccelerators.isEmpty) return;
    final hasPreferred = manifest.preferredAccelerators.any(device.supports);
    if (!hasPreferred) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.accelerator,
        severity: CompatibilitySeverity.warning,
        message: 'None of the accelerators "${manifest.id}" prefers '
            '(${manifest.preferredAccelerators.map((a) => a.name).join(", ")}) '
            'are available; it will fall back to CPU.',
      ));
    }
  }

  static void _checkContextWindow(
    List<CompatibilityIssue> issues,
    LocalModelManifest manifest,
    int? requestedContextTokens,
  ) {
    final limit = manifest.contextLength;
    if (limit == null || requestedContextTokens == null) return;
    if (requestedContextTokens > limit) {
      issues.add(CompatibilityIssue(
        check: CompatibilityCheck.contextWindow,
        severity: CompatibilitySeverity.warning,
        message: 'Configured context of $requestedContextTokens tokens '
            'exceeds the $limit-token window of "${manifest.id}"; it will be '
            'clamped.',
      ));
    }
  }
}
