/// Platform-specific source for device memory and disk metrics.
library;

import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:local_ai_core/local_ai_core.dart';

typedef DeviceProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Supplies the metrics used by [FlutterDeviceProbe].
abstract interface class DeviceMetricsSource {
  Future<DeviceCapabilities> read();
}

/// Reads memory and disk metrics from device_info_plus or native OS tools.
class SystemDeviceMetricsSource implements DeviceMetricsSource {
  SystemDeviceMetricsSource({
    DeviceInfoPlugin? deviceInfo,
    DeviceProcessRunner? processRunner,
    String? dataPath,
  })  : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _processRunner = processRunner ?? Process.run,
        _dataPath = dataPath ?? Directory.current.path;

  final DeviceInfoPlugin _deviceInfo;
  final DeviceProcessRunner _processRunner;
  final String _dataPath;

  @override
  Future<DeviceCapabilities> read() async {
    final accelerators = <Accelerator>{Accelerator.cpu};
    var totalMemoryMB = 0;
    var availableMemoryMB = 0;
    var freeDiskMB = 0;
    String? socModel;

    if (Platform.isAndroid) {
      final info = await _deviceInfo.androidInfo;
      totalMemoryMB = _bytesToMB(info.physicalRamSize);
      availableMemoryMB = _bytesToMB(info.availableRamSize);
      freeDiskMB = _bytesToMB(info.freeDiskSize);
      socModel = info.model;
      accelerators
        ..add(Accelerator.gpu)
        ..add(Accelerator.nnapi);
    } else if (Platform.isIOS) {
      final info = await _deviceInfo.iosInfo;
      totalMemoryMB = _bytesToMB(info.physicalRamSize);
      availableMemoryMB = _bytesToMB(info.availableRamSize);
      freeDiskMB = _bytesToMB(info.freeDiskSize);
      socModel = info.utsname.machine;
      accelerators
        ..add(Accelerator.metal)
        ..add(Accelerator.neuralEngine);
    } else if (Platform.isLinux) {
      final memory = DeviceMetricsParsers.linuxMemory(
        await _runText('cat', ['/proc/meminfo']),
      );
      totalMemoryMB = memory.totalMB;
      availableMemoryMB = memory.availableMB;
      freeDiskMB = DeviceMetricsParsers.freeDiskMB(
        await _runText('df', ['-k', _dataPath]),
      );
    } else if (Platform.isMacOS) {
      final totalMemory = _parseInt(
        await _runText('sysctl', ['-n', 'hw.memsize']),
      );
      final memory = DeviceMetricsParsers.macOsMemory(
        totalBytes: totalMemory,
        vmStatOutput: await _runText('vm_stat', const []),
      );
      totalMemoryMB = memory.totalMB;
      availableMemoryMB = memory.availableMB;
      freeDiskMB = DeviceMetricsParsers.freeDiskMB(
        await _runText('df', ['-k', _dataPath]),
      );
    } else if (Platform.isWindows) {
      final memory = DeviceMetricsParsers.windowsMemory(
        await _runText('powershell', [
          '-NoProfile',
          '-Command',
          'Get-CimInstance Win32_OperatingSystem | '
              'Select-Object TotalVisibleMemorySize,FreePhysicalMemory | '
              'ConvertTo-Csv -NoTypeInformation',
        ]),
      );
      totalMemoryMB = memory.totalMB;
      availableMemoryMB = memory.availableMB;
      final drive =
          RegExp(r'^[A-Za-z]:').firstMatch(_dataPath)?.group(0) ?? 'C:';
      freeDiskMB = _bytesToMB(
        _parseInt(
          await _runText('powershell', [
            '-NoProfile',
            '-Command',
            '(Get-CimInstance Win32_LogicalDisk '
                '-Filter "DeviceID=\'$drive\'").FreeSpace',
          ]),
        ),
      );
    }

    return DeviceCapabilities(
      totalMemoryMB: totalMemoryMB,
      availableMemoryMB: availableMemoryMB,
      freeDiskMB: freeDiskMB,
      platform: Platform.operatingSystem,
      socModel: socModel?.isEmpty ?? true ? null : socModel,
      accelerators: accelerators,
    );
  }

  Future<String> _runText(String executable, List<String> arguments) async {
    try {
      final result = await _processRunner(executable, arguments);
      if (result.exitCode != 0) return '';
      return result.stdout.toString();
    } on Object {
      return '';
    }
  }

  static int _parseInt(String value) => int.tryParse(value.trim()) ?? 0;

  static int _bytesToMB(int bytes) => bytes <= 0 ? 0 : bytes ~/ (1024 * 1024);
}

/// Pure parsers kept separate from process and plugin access for fixture tests.
abstract final class DeviceMetricsParsers {
  static ({int totalMB, int availableMB}) linuxMemory(String output) {
    final values = <String, int>{};
    for (final line in const LineSplitter().convert(output)) {
      final match = RegExp(r'^(MemTotal|MemAvailable):\s+(\d+)\s+kB$')
          .firstMatch(line.trim());
      if (match != null) values[match.group(1)!] = int.parse(match.group(2)!);
    }
    return (
      totalMB: (values['MemTotal'] ?? 0) ~/ 1024,
      availableMB: (values['MemAvailable'] ?? 0) ~/ 1024,
    );
  }

  static ({int totalMB, int availableMB}) macOsMemory({
    required int totalBytes,
    required String vmStatOutput,
  }) {
    final pageSizeMatch =
        RegExp(r'page size of (\d+) bytes').firstMatch(vmStatOutput);
    final pageSize = int.tryParse(pageSizeMatch?.group(1) ?? '') ?? 4096;
    var availablePages = 0;
    for (final line in const LineSplitter().convert(vmStatOutput)) {
      if (!RegExp(r'^Pages (free|inactive|speculative):').hasMatch(line)) {
        continue;
      }
      final match = RegExp(r'(\d+)\.?\s*$').firstMatch(line.trim());
      availablePages += int.tryParse(match?.group(1) ?? '') ?? 0;
    }
    return (
      totalMB: totalBytes <= 0 ? 0 : totalBytes ~/ (1024 * 1024),
      availableMB: (availablePages * pageSize) ~/ (1024 * 1024),
    );
  }

  static int freeDiskMB(String output) {
    final lines = const LineSplitter()
        .convert(output)
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return 0;
    final fields = lines[1].trim().split(RegExp(r'\s+'));
    if (fields.length < 4) return 0;
    final availableBlocks = int.tryParse(fields[3]) ?? 0;
    return availableBlocks <= 0 ? 0 : availableBlocks ~/ 1024;
  }

  static ({int totalMB, int availableMB}) windowsMemory(String output) {
    final lines = const LineSplitter()
        .convert(output)
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return (totalMB: 0, availableMB: 0);
    final headers = _csvFields(lines[0]);
    final values = _csvFields(lines[1]);
    final totalIndex = headers.indexOf('TotalVisibleMemorySize');
    final availableIndex = headers.indexOf('FreePhysicalMemory');
    if (totalIndex < 0 ||
        availableIndex < 0 ||
        totalIndex >= values.length ||
        availableIndex >= values.length) {
      return (totalMB: 0, availableMB: 0);
    }
    final totalKB = int.tryParse(values[totalIndex]) ?? 0;
    final availableKB = int.tryParse(values[availableIndex]) ?? 0;
    return (totalMB: totalKB ~/ 1024, availableMB: availableKB ~/ 1024);
  }

  static List<String> _csvFields(String line) => line
      .split(',')
      .map((field) => field.trim().replaceAll(RegExp(r'^"|"$'), ''))
      .toList();
}
