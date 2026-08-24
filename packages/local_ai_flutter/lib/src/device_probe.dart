/// Device capability probing (RAM / disk / accelerators).
library;

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:local_ai_core/local_ai_core.dart';

/// Probes the device once and caches the resulting [DeviceCapabilities].
///
/// Used by `RuntimeScheduler.checkCompatibility`.
class FlutterDeviceProbe {
  FlutterDeviceProbe({DeviceInfoPlugin? deviceInfo})
      : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;
  DeviceCapabilities? _cached;

  /// Probes (once) and returns device capabilities.
  Future<DeviceCapabilities> probe() async {
    final cached = _cached;
    if (cached != null) return cached;

    var totalMemoryMB = 0;
    var availableMemoryMB = 0;
    var socModel = '';
    final accelerators = <Accelerator>{Accelerator.cpu};

    if (Platform.isAndroid) {
      final info = await _deviceInfo.androidInfo;
      // TODO(verify): device_info_plus does not expose RAM directly; RAM
      // needs a platform channel reading /proc/meminfo or
      // ActivityManager.MemoryInfo. Fall back to a conservative estimate.
      totalMemoryMB = 4096;
      availableMemoryMB = 2048;
      // TODO(verify): `info.socModel` requires API 31+; guard accordingly.
      socModel = info.model;
      accelerators.add(Accelerator.gpu);
      accelerators.add(Accelerator.nnapi);
    } else if (Platform.isIOS) {
      final info = await _deviceInfo.iosInfo;
      // TODO(verify): iOS RAM via platform channel (NSProcessInfo
      // physicalMemory). Conservative estimate for now.
      totalMemoryMB = 4096;
      availableMemoryMB = 2048;
      socModel = info.utsname.machine;
      accelerators.add(Accelerator.metal);
      accelerators.add(Accelerator.neuralEngine);
    }

    final freeDiskMB = await _freeDiskMB();

    return _cached = DeviceCapabilities(
      totalMemoryMB: totalMemoryMB,
      availableMemoryMB: availableMemoryMB,
      freeDiskMB: freeDiskMB,
      platform: Platform.operatingSystem,
      socModel: socModel.isEmpty ? null : socModel,
      accelerators: accelerators,
    );
  }

  /// Free disk space on the data partition, in MB.
  Future<int> _freeDiskMB() async {
    // TODO(verify): dart:io has no free-space API; requires a platform
    // channel (statfs / NSURLVolumeAvailableCapacityKey). Until then report
    // a large placeholder so preflight checks don't hard-fail; replace with
    // a real probe before release.
    return 100 * 1024;
  }
}