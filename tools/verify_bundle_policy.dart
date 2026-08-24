/// Verifies the bundle-size policy: assets declared `bundled` (or resolved
/// `bundled` via `ModelDeliveryPolicy.smart`) must stay below the
/// `bundleBelowMB` threshold (architecture §4.3, melos `verify:bundle-policy`).
///
/// Run: `dart run tools/verify_bundle_policy.dart [assetsDir]`
library;

import 'dart:io';

void main(List<String> args) {
  final assetsDir = args.isNotEmpty ? args[0] : 'packages/local_ai_kit/assets';
  const thresholdMB = 25; // keep in sync with ModelDeliveryPolicy.smart()

  final dir = Directory(assetsDir);
  if (!dir.existsSync()) {
    stdout.writeln('no bundled assets directory ($assetsDir) — OK');
    return;
  }

  var failures = 0;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith(RegExp(r'(onnx|tflite|task|bin)$'))) continue;
    final sizeMB = entity.lengthSync() / (1024 * 1024);
    if (sizeMB >= thresholdMB) {
      stderr.writeln(
          'FAIL: ${entity.path} is ${sizeMB.toStringAsFixed(1)}MB '
          '(>= ${thresholdMB}MB threshold). Mark it `download` delivery.');
      failures++;
    } else {
      stdout.writeln(
          'ok: ${entity.path} (${sizeMB.toStringAsFixed(2)}MB)');
    }
  }

  if (failures > 0) exitCode = 1;
}
