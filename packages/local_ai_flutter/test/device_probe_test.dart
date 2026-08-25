import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_flutter/src/device_metrics_source.dart';
import 'package:local_ai_flutter/src/device_probe.dart';

void main() {
  test('FlutterDeviceProbe caches the injected metrics source', () async {
    final source = _FakeDeviceMetricsSource(
      const DeviceCapabilities(
        totalMemoryMB: 8192,
        availableMemoryMB: 4096,
        freeDiskMB: 10000,
        platform: 'test',
      ),
    );
    final probe = FlutterDeviceProbe(metricsSource: source);

    final first = await probe.probe();
    final second = await probe.probe();

    expect(first.totalMemoryMB, 8192);
    expect(identical(first, second), isTrue);
    expect(source.readCount, 1);
  });
}

final class _FakeDeviceMetricsSource implements DeviceMetricsSource {
  _FakeDeviceMetricsSource(this.capabilities);

  final DeviceCapabilities capabilities;
  var readCount = 0;

  @override
  Future<DeviceCapabilities> read() async {
    readCount++;
    return capabilities;
  }
}
