/// Device capability probing (RAM / disk / accelerators).
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:local_ai_core/local_ai_core.dart';

import 'device_metrics_source.dart';

/// Probes the device once and caches the resulting [DeviceCapabilities].
///
/// Used by `RuntimeScheduler.checkCompatibility`.
class FlutterDeviceProbe {
  FlutterDeviceProbe({
    DeviceInfoPlugin? deviceInfo,
    DeviceMetricsSource? metricsSource,
  }) : _metricsSource =
            metricsSource ?? SystemDeviceMetricsSource(deviceInfo: deviceInfo);

  final DeviceMetricsSource _metricsSource;
  DeviceCapabilities? _cached;

  /// Probes (once) and returns device capabilities.
  Future<DeviceCapabilities> probe() async {
    final cached = _cached;
    if (cached != null) return cached;

    return _cached = await _metricsSource.read();
  }
}
