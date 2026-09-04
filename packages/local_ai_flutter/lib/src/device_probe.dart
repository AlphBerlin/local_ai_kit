/// Device capability probing (RAM / disk / accelerators).
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:local_ai_core/local_ai_core.dart';

import 'device_metrics_source.dart';

/// Probes the device and caches the resulting [DeviceCapabilities] for
/// [cacheDuration].
///
/// Backs `RuntimeScheduler.checkCompatibility` and the download manager's
/// disk pre-flight, and is wired as the default probe by
/// `LocalAI.initialize`.
///
/// The cache has a lifetime rather than being permanent because two of the
/// four metrics move while the app runs: free RAM changes as models load
/// and unload, and free disk changes as models are downloaded. Gating a
/// 2 GB download on a disk reading taken at app start would let a second
/// download start against space the first one already claimed.
class FlutterDeviceProbe {
  FlutterDeviceProbe({
    DeviceInfoPlugin? deviceInfo,
    DeviceMetricsSource? metricsSource,
    this.cacheDuration = const Duration(seconds: 30),
    DateTime Function()? now,
  })  : _metricsSource =
            metricsSource ?? SystemDeviceMetricsSource(deviceInfo: deviceInfo),
        _now = now ?? DateTime.now;

  final DeviceMetricsSource _metricsSource;
  final DateTime Function() _now;

  /// How long a probe result is reused before the device is read again.
  /// [Duration.zero] disables caching; a very large value restores the
  /// previous probe-once behaviour.
  final Duration cacheDuration;

  DeviceCapabilities? _cached;
  DateTime? _cachedAt;

  /// Probes the device, reusing a result younger than [cacheDuration].
  ///
  /// Pass `forceRefresh: true` before a decision that must see current
  /// numbers (offering a large download, retrying a load that failed for
  /// memory).
  Future<DeviceCapabilities> probe({bool forceRefresh = false}) async {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        _now().difference(cachedAt) < cacheDuration) {
      return cached;
    }
    final result = await _metricsSource.read();
    _cached = result;
    _cachedAt = _now();
    return result;
  }

  /// Drops the cached snapshot; the next [probe] reads the device.
  void invalidate() {
    _cached = null;
    _cachedAt = null;
  }
}
