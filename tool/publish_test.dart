import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('publisher CLI exposes help without publishing', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'tool/publish.dart', '--help'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0);
    expect(result.stdout, contains('--dry-run'));
    expect(result.stdout, contains('--publish'));
  });
}
