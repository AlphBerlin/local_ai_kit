import 'dart:io';

import 'release_config.dart';

const _usage = '''
Usage: dart run tool/publish.dart --dry-run
       dart run tool/publish.dart --publish

Publishes all LocalAI Kit packages in dependency order.
''';

Future<void> main(List<String> args) async {
  final mode = _parseMode(args);
  if (mode == null) {
    stdout.write(_usage);
    exitCode = args.contains('--help') ? 0 : 64;
    return;
  }

  try {
    final versions = <String, String>{};
    for (final package in releasePackages) {
      versions[package.name] = await _readVersion(package);
    }
    final version = validateReleaseVersion(versions);
    _validateTag(version);

    for (final package in releasePackages) {
      final executable = package.usesFlutter ? 'flutter' : 'dart';
      final command = <String>[
        'pub',
        'publish',
        if (mode == _PublishMode.dryRun) '--dry-run' else '--force',
      ];
      final directory = Directory(package.directory).absolute.path;
      stdout.writeln(
        '==> ${package.name} $version '
        '(${[executable, ...command].join(' ')})',
      );

      final result = await Process.run(
        executable,
        command,
        workingDirectory: directory,
      );
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      if (result.exitCode != 0) {
        stderr.writeln(
          'Publishing ${package.name} failed with exit code '
          '${result.exitCode}.',
        );
        exitCode = result.exitCode;
        return;
      }
    }

    stdout.writeln(
      mode == _PublishMode.dryRun
          ? 'All packages passed publication dry-run.'
          : 'All packages published successfully.',
    );
  } on ReleaseValidationException catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln('Unable to inspect package metadata: $error');
    exitCode = 66;
  }
}

enum _PublishMode { dryRun, publish }

_PublishMode? _parseMode(List<String> args) {
  if (args.length == 1 && args.single == '--dry-run') {
    return _PublishMode.dryRun;
  }
  if (args.length == 1 && args.single == '--publish') {
    return _PublishMode.publish;
  }
  if (args.length == 1 && args.single == '--help') {
    return null;
  }
  stderr.writeln('Expected exactly one of --dry-run or --publish.');
  return null;
}

Future<String> _readVersion(ReleasePackage package) async {
  final pubspec = File('${package.directory}/pubspec.yaml');
  final contents = await pubspec.readAsString();
  final match = RegExp(r'^version:\s*([^\s#]+)', multiLine: true)
      .firstMatch(contents);
  if (match == null) {
    throw ReleaseValidationException(
      'Package ${package.name} has no version in ${pubspec.path}.',
    );
  }
  return match.group(1)!;
}

void _validateTag(String version) {
  final tag = Platform.environment['GITHUB_REF_NAME'];
  if (tag == null || tag.isEmpty) {
    return;
  }

  final match = RegExp(r'^v(\d+\.\d+\.\d+)$').firstMatch(tag);
  if (match == null || match.group(1) != version) {
    throw ReleaseValidationException(
      'Package version $version does not match GitHub tag $tag.',
    );
  }
}
