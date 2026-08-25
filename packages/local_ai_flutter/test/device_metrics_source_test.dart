import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_flutter/src/device_metrics_source.dart';

void main() {
  group('DeviceMetricsParsers', () {
    test('parses Linux memory values in kB', () {
      const fixture = '''
MemTotal:       16384000 kB
MemFree:         1024000 kB
MemAvailable:    8192000 kB
''';

      expect(DeviceMetricsParsers.linuxMemory(fixture),
          (totalMB: 16000, availableMB: 8000));
    });

    test('parses macOS memory values and available pages', () {
      const fixture = '''
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                               1000.
Pages active:                           20000.
Pages inactive:                          3000.
Pages speculative:                        500.
''';

      expect(
        DeviceMetricsParsers.macOsMemory(
          totalBytes: 16 * 1024 * 1024 * 1024,
          vmStatOutput: fixture,
        ),
        (totalMB: 16384, availableMB: 17),
      );
    });

    test('parses df output and reports malformed output as unknown', () {
      const fixture = '''
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk1 1000000 400000 600000 40% /
''';

      expect(DeviceMetricsParsers.freeDiskMB(fixture), 585);
      expect(DeviceMetricsParsers.freeDiskMB('not df output'), 0);
    });

    test('parses Windows CIM CSV memory values', () {
      const fixture =
          '"TotalVisibleMemorySize","FreePhysicalMemory"\n"16777216","8388608"\n';

      expect(DeviceMetricsParsers.windowsMemory(fixture),
          (totalMB: 16384, availableMB: 8192));
    });
  });
}
