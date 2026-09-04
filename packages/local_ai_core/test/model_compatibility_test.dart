import 'package:local_ai_core/local_ai_core.dart';
import 'package:test/test.dart';

LocalModelManifest manifest({
  int minMemoryMB = 0,
  int sizeBytes = 0,
  List<String> platforms = const ['android', 'ios'],
  int? contextLength,
  Set<Accelerator> required = const {},
  Set<Accelerator> preferred = const {},
}) {
  return LocalModelManifest(
    id: 'test-model',
    type: ModelType.llm,
    provider: 'test-provider',
    delivery: ModelDelivery.download,
    platforms: platforms,
    minMemoryMB: minMemoryMB,
    contextLength: contextLength,
    requiredAccelerators: required,
    preferredAccelerators: preferred,
    files: [
      ModelFile(
        name: 'weights.bin',
        url: 'https://example.invalid/weights.bin',
        sha256: kPlaceholderSha256,
        sizeBytes: sizeBytes,
      ),
    ],
  );
}

const int mb = 1024 * 1024;

DeviceCapabilities device({
  int totalMemoryMB = 8192,
  int availableMemoryMB = 6144,
  int freeDiskMB = 65536,
  String platform = 'android',
  Set<Accelerator> accelerators = const {Accelerator.cpu},
}) {
  return DeviceCapabilities(
    totalMemoryMB: totalMemoryMB,
    availableMemoryMB: availableMemoryMB,
    freeDiskMB: freeDiskMB,
    platform: platform,
    accelerators: accelerators,
  );
}

Iterable<CompatibilityIssue> of(
  CompatibilityReport report,
  CompatibilityCheck check,
) =>
    report.issues.where((i) => i.check == check);

void main() {
  group('platform', () {
    test('a listed platform is compatible', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(),
        device: device(platform: 'android'),
      );
      expect(report.isCompatible, isTrue);
      expect(of(report, CompatibilityCheck.platform), isEmpty);
    });

    test('an unlisted platform blocks and names the supported set', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(platforms: ['android', 'ios']),
        device: device(platform: 'linux'),
      );
      expect(report.isCompatible, isFalse);
      expect(report.reasons.single, contains('does not support linux'));
      expect(report.reasons.single, contains('android, ios'));
    });

    test('an unknown platform warns instead of blocking', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(),
        device: device(platform: 'unknown'),
      );
      expect(report.isCompatible, isTrue);
      expect(
        of(report, CompatibilityCheck.unknown).map((i) => i.message),
        contains(contains('Platform could not be detected')),
      );
    });

    test('an empty platform list means "runs anywhere"', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(platforms: const []),
        device: device(platform: 'fuchsia'),
      );
      expect(report.isCompatible, isTrue);
    });
  });

  group('memory', () {
    test('a device below the declared minimum is blocked', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 6000),
        device: device(totalMemoryMB: 3000, availableMemoryMB: 2000),
      );
      expect(report.isCompatible, isFalse);
      final issue = of(report, CompatibilityCheck.totalMemory).single;
      expect(issue.requiredMB, 6000);
      expect(issue.availableMB, 3000);
    });

    test('a total-RAM failure does not also report available RAM', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 6000),
        device: device(totalMemoryMB: 3000, availableMemoryMB: 100),
      );
      expect(of(report, CompatibilityCheck.availableMemory), isEmpty);
    });

    test('a momentary shortfall warns but does not block by default', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 2000),
        device: device(totalMemoryMB: 8192, availableMemoryMB: 1000),
      );
      expect(report.isCompatible, isTrue);
      expect(report.hasWarnings, isTrue);
      expect(of(report, CompatibilityCheck.availableMemory).single.isBlocking,
          isFalse);
    });

    test('the strict policy makes a momentary shortfall blocking', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 2000),
        device: device(totalMemoryMB: 8192, availableMemoryMB: 1000),
        policy: const ModelCompatibilityPolicy.strict(),
      );
      expect(report.isCompatible, isFalse);
      expect(of(report, CompatibilityCheck.availableMemory).single.isBlocking,
          isTrue);
    });

    test('a tight-but-sufficient fit warns about headroom', () {
      // 2000MB needed, 1.25x headroom = 2500MB recommended.
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 2000),
        device: device(totalMemoryMB: 8192, availableMemoryMB: 2200),
      );
      expect(report.isCompatible, isTrue);
      expect(of(report, CompatibilityCheck.availableMemory).single.message,
          contains('RAM is tight'));
    });

    test('comfortable RAM produces no memory issue at all', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 2000),
        device: device(totalMemoryMB: 8192, availableMemoryMB: 6144),
      );
      expect(of(report, CompatibilityCheck.availableMemory), isEmpty);
      expect(of(report, CompatibilityCheck.totalMemory), isEmpty);
    });

    test('unprobed RAM warns rather than passing or failing silently', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 6000),
        device: device(totalMemoryMB: 0, availableMemoryMB: 0),
      );
      expect(report.isCompatible, isTrue);
      expect(
        of(report, CompatibilityCheck.unknown).map((i) => i.message),
        contains(contains('Total RAM could not be probed')),
      );
    });

    group('estimated from file size', () {
      // 2048MB of weights → ceil(2048*1.15) + 256 = 2356 + 256 = 2612MB.
      final big = manifest(sizeBytes: 2048 * mb);

      test('an estimate warns but never blocks', () {
        final report = ModelCompatibilityChecker.check(
          manifest: big,
          device: device(totalMemoryMB: 1024, availableMemoryMB: 512),
        );
        expect(report.isCompatible, isTrue,
            reason: 'a heuristic over file sizes must not block a download');
        final issue = of(report, CompatibilityCheck.totalMemory).single;
        expect(issue.isBlocking, isFalse);
        expect(issue.message, contains('estimated from download size'));
        expect(issue.requiredMB, 2612);
      });

      test('the estimate can be switched off', () {
        final report = ModelCompatibilityChecker.check(
          manifest: big,
          device: device(totalMemoryMB: 1024, availableMemoryMB: 512),
          policy: const ModelCompatibilityPolicy.permissive(),
        );
        expect(of(report, CompatibilityCheck.totalMemory), isEmpty);
      });

      test('a declared minMemoryMB wins over the estimate', () {
        final report = ModelCompatibilityChecker.check(
          manifest: manifest(minMemoryMB: 512, sizeBytes: 2048 * mb),
          device: device(totalMemoryMB: 1024, availableMemoryMB: 900),
        );
        expect(of(report, CompatibilityCheck.totalMemory), isEmpty);
      });
    });
  });

  group('disk', () {
    test('too little free disk blocks the download', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(sizeBytes: 1000 * mb),
        device: device(freeDiskMB: 900),
      );
      expect(report.isCompatible, isFalse);
      final issue = of(report, CompatibilityCheck.disk).single;
      expect(issue.requiredMB, 1200, reason: '1000MB x 1.2 headroom');
      expect(issue.availableMB, 900);
    });

    test('enough free disk including headroom passes', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(sizeBytes: 1000 * mb),
        device: device(freeDiskMB: 1300),
      );
      expect(of(report, CompatibilityCheck.disk), isEmpty);
    });

    test('free disk between the raw size and the headroom still blocks', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(sizeBytes: 1000 * mb),
        device: device(freeDiskMB: 1100),
      );
      expect(report.isCompatible, isFalse);
    });

    test('unprobed disk warns rather than blocking', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(sizeBytes: 1000 * mb),
        device: device(freeDiskMB: 0),
      );
      expect(report.isCompatible, isTrue);
      expect(
        of(report, CompatibilityCheck.unknown).map((i) => i.message),
        contains(contains('Free disk space could not be probed')),
      );
    });

    test('requiredDiskMB matches what the disk check enforces', () {
      final m = manifest(sizeBytes: 1000 * mb);
      expect(ModelCompatibilityChecker.requiredDiskMB(m), 1200);
    });
  });

  group('accelerators', () {
    test('a missing required accelerator blocks', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(required: {Accelerator.nnapi}),
        device: device(accelerators: {Accelerator.cpu}),
      );
      expect(report.isCompatible, isFalse);
      expect(report.reasons.single, contains('requires the nnapi backend'));
    });

    test('a present required accelerator passes', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(required: {Accelerator.gpu}),
        device: device(accelerators: {Accelerator.cpu, Accelerator.gpu}),
      );
      expect(report.isCompatible, isTrue);
    });

    test('no preferred accelerator warns about the CPU fallback', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(preferred: {Accelerator.gpu, Accelerator.nnapi}),
        device: device(accelerators: {Accelerator.cpu}),
      );
      expect(report.isCompatible, isTrue);
      expect(of(report, CompatibilityCheck.accelerator).single.message,
          contains('fall back to CPU'));
    });

    test('one matching preferred accelerator is enough to silence it', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(preferred: {Accelerator.gpu, Accelerator.nnapi}),
        device: device(accelerators: {Accelerator.cpu, Accelerator.gpu}),
      );
      expect(of(report, CompatibilityCheck.accelerator), isEmpty);
    });
  });

  group('context window', () {
    test('a request beyond the model window warns', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(contextLength: 4096),
        device: device(),
        requestedContextTokens: 8192,
      );
      expect(report.isCompatible, isTrue);
      expect(of(report, CompatibilityCheck.contextWindow).single.message,
          contains('will be clamped'));
    });

    test('a request within the window is silent', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(contextLength: 8192),
        device: device(),
        requestedContextTokens: 4096,
      );
      expect(of(report, CompatibilityCheck.contextWindow), isEmpty);
    });

    test('no requested context means no check', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(contextLength: 512),
        device: device(),
      );
      expect(of(report, CompatibilityCheck.contextWindow), isEmpty);
    });
  });

  group('report', () {
    test('blockers and warnings are reported separately', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(
          minMemoryMB: 2000,
          sizeBytes: 1000 * mb,
          platforms: const ['ios'],
          preferred: {Accelerator.gpu},
        ),
        device: device(
          platform: 'android',
          totalMemoryMB: 8192,
          availableMemoryMB: 2100,
          freeDiskMB: 100,
        ),
      );
      expect(report.isCompatible, isFalse);
      expect(report.blockers.map((i) => i.check),
          containsAll([CompatibilityCheck.platform, CompatibilityCheck.disk]));
      expect(
          report.warnings.map((i) => i.check),
          containsAll([
            CompatibilityCheck.availableMemory,
            CompatibilityCheck.accelerator,
          ]));
      expect(report.reasons.length, report.blockers.length);
    });

    test('summary reads "compatible" only when nothing was found', () {
      final clean = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 1000, sizeBytes: 10 * mb),
        device: device(),
      );
      expect(clean.summary, 'compatible');

      final warned = ModelCompatibilityChecker.check(
        manifest: manifest(minMemoryMB: 1000, sizeBytes: 10 * mb),
        device: device(availableMemoryMB: 1050),
      );
      expect(warned.isCompatible, isTrue);
      expect(warned.summary, startsWith('compatible with warnings:'));
    });

    test('IncompatibleDeviceError carries the whole report', () {
      final report = ModelCompatibilityChecker.check(
        manifest: manifest(platforms: const ['ios']),
        device: device(platform: 'android'),
      );
      final error = IncompatibleDeviceError(report);
      expect(error.report, same(report));
      expect(error.message, contains('does not support android'));
    });
  });

  group('manifest accelerator round-trip', () {
    test('accelerator sets survive json', () {
      final original = manifest(
        required: {Accelerator.nnapi},
        preferred: {Accelerator.gpu, Accelerator.metal},
      );
      final decoded = LocalModelManifest.fromJson(original.toJson());
      expect(decoded.requiredAccelerators, {Accelerator.nnapi});
      expect(
          decoded.preferredAccelerators, {Accelerator.gpu, Accelerator.metal});
    });

    test('empty sets are omitted from json', () {
      final json = manifest().toJson();
      expect(json.containsKey('requiredAccelerators'), isFalse);
      expect(json.containsKey('preferredAccelerators'), isFalse);
    });

    test('an unknown accelerator name from a newer catalog is skipped', () {
      final json = manifest(required: {Accelerator.gpu}).toJson()
        ..['requiredAccelerators'] = ['gpu', 'quantum_tpu'];
      final decoded = LocalModelManifest.fromJson(json);
      expect(decoded.requiredAccelerators, {Accelerator.gpu});
    });
  });
}
