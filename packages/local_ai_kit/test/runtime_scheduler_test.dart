import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_kit/src/runtime/runtime_scheduler.dart';

/// A `LocalLlm` whose `load` blocks until the test releases it, so a load
/// can be observed mid-flight.
class _SlowLlm extends FakeLlm {
  _SlowLlm({this.gate});

  /// When set, `load` waits on this before completing.
  final Completer<void>? gate;

  int loadCount = 0;
  int unloadCount = 0;
  Object? failWith;

  @override
  Future<void> load(LlmLoadOptions options) async {
    loadCount++;
    if (gate != null) await gate!.future;
    final failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<void> unload() async => unloadCount++;
}

class _TestCatalog implements LocalModelCatalog {
  _TestCatalog(this.manifests);

  final Map<String, LocalModelManifest> manifests;

  @override
  Future<LocalModelManifest> get(String modelId) async {
    final manifest = manifests[modelId];
    if (manifest == null) throw ModelNotFoundError(modelId);
    return manifest;
  }

  @override
  Future<List<LocalModelManifest>> list({
    ModelType? type,
    String? language,
  }) async =>
      manifests.values.where((m) => type == null || m.type == type).toList();

  @override
  List<ModelPack> get packs => const [];

  @override
  Future<void> installPack(String packId) async =>
      throw UnsupportedError('not used');

  @override
  Future<void> refresh() async {}
}

/// A clock the test advances by hand, so LRU and idle behaviour is
/// deterministic instead of wall-clock dependent.
class _ManualClock implements Clock {
  DateTime _now = DateTime.utc(2026, 1, 1);

  @override
  DateTime now() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

LocalModelManifest llmManifest(
  String id, {
  int minMemoryMB = 0,
  int sizeBytes = 0,
  List<String> platforms = const ['android'],
}) =>
    LocalModelManifest(
      id: id,
      type: ModelType.llm,
      provider: 'test-provider',
      delivery: ModelDelivery.download,
      platforms: platforms,
      minMemoryMB: minMemoryMB,
      files: [
        ModelFile(
          name: '$id.bin',
          url: 'https://example.invalid/$id.bin',
          sha256: kPlaceholderSha256,
          sizeBytes: sizeBytes,
        ),
      ],
    );

const _androidDevice = DeviceCapabilities(
  totalMemoryMB: 8192,
  availableMemoryMB: 6144,
  freeDiskMB: 65536,
  platform: 'android',
);

void main() {
  late _ManualClock clock;

  RuntimeScheduler build({
    required Map<String, LocalLlm> adapters,
    Map<String, LocalModelManifest>? manifests,
    RuntimeMemoryPolicy policy = const RuntimeMemoryPolicy(),
    Future<DeviceCapabilities> Function()? deviceProbe,
    CompatibilityEnforcement enforcement = CompatibilityEnforcement.enforce,
  }) {
    final registry = AdapterRegistry();
    final catalog = _TestCatalog(
        manifests ?? {for (final id in adapters.keys) id: llmManifest(id)});
    // One factory per provider, so route each model through its own
    // provider key.
    for (final entry in adapters.entries) {
      registry.registerLlm('provider-${entry.key}', (_) => entry.value);
    }
    final routed = <String, LocalModelManifest>{
      for (final entry in catalog.manifests.entries)
        entry.key: LocalModelManifest(
          id: entry.value.id,
          type: entry.value.type,
          provider: 'provider-${entry.key}',
          delivery: entry.value.delivery,
          platforms: entry.value.platforms,
          minMemoryMB: entry.value.minMemoryMB,
          files: entry.value.files,
        ),
    };
    return RuntimeScheduler(
      catalog: _TestCatalog(routed),
      registry: registry,
      policy: policy,
      clock: clock,
      deviceProbe: deviceProbe ?? () async => _androidDevice,
      compatibilityEnforcement: enforcement,
      // Long enough that no sweep fires unless a test asks for one.
      sweepInterval: const Duration(hours: 1),
    );
  }

  setUp(() => clock = _ManualClock());

  group('load coalescing', () {
    test('concurrent loads of one model produce a single native load',
        () async {
      final gate = Completer<void>();
      final llm = _SlowLlm(gate: gate);
      final scheduler = build(adapters: {'a': llm});
      addTearDown(scheduler.dispose);

      final first = scheduler.loadModel('a');
      final second = scheduler.loadModel('a');
      final third = scheduler.loadModel('a');
      await pumpEventQueue();

      expect(llm.loadCount, 1,
          reason: 'the second and third callers must join the first load');

      gate.complete();
      await Future.wait([first, second, third]);

      expect(llm.loadCount, 1);
      expect(scheduler.isLoaded('a'), isTrue);
      expect(scheduler.loadedModels, hasLength(1));
    });

    test('a joined load completes for every caller', () async {
      final gate = Completer<void>();
      final scheduler = build(adapters: {'a': _SlowLlm(gate: gate)});
      addTearDown(scheduler.dispose);

      final futures = [
        scheduler.loadModel('a'),
        scheduler.loadModel('a'),
      ];
      await pumpEventQueue();
      gate.complete();

      await expectLater(Future.wait(futures), completes);
    });

    test('a failing load propagates to every joined caller', () async {
      final gate = Completer<void>();
      final llm = _SlowLlm(gate: gate)..failWith = StateError('boom');
      final scheduler = build(adapters: {'a': llm});
      addTearDown(scheduler.dispose);

      final first = scheduler.loadModel('a', preference: RuntimePreference.cpu);
      final second =
          scheduler.loadModel('a', preference: RuntimePreference.cpu);
      await pumpEventQueue();
      gate.complete();

      await expectLater(first, throwsA(isA<StateError>()));
      await expectLater(second, throwsA(isA<StateError>()));
      expect(scheduler.isLoaded('a'), isFalse);
    });

    test('a load can be retried after a failure', () async {
      final llm = _SlowLlm()..failWith = StateError('boom');
      final scheduler = build(adapters: {'a': llm});
      addTearDown(scheduler.dispose);

      await expectLater(
        scheduler.loadModel('a', preference: RuntimePreference.cpu),
        throwsA(isA<StateError>()),
      );
      llm.failWith = null;
      await scheduler.loadModel('a', preference: RuntimePreference.cpu);
      expect(scheduler.isLoaded('a'), isTrue);
    });

    test('loadModel returns rather than hanging when already loaded', () async {
      final llm = _SlowLlm();
      final scheduler = build(adapters: {'a': llm});
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      await scheduler.loadModel('a').timeout(const Duration(seconds: 2));

      expect(llm.loadCount, 1);
    });
  });

  group('load progress', () {
    test('a load walks the phases and ends on ready', () async {
      final scheduler = build(adapters: {'a': _SlowLlm()});
      addTearDown(scheduler.dispose);

      final phases = <ModelLoadPhase>[];
      final sub =
          scheduler.loadProgress('a').listen((p) => phases.add(p.phase));
      addTearDown(sub.cancel);

      await scheduler.loadModel('a');
      await pumpEventQueue();

      expect(phases.first, ModelLoadPhase.queued);
      expect(phases.last, ModelLoadPhase.ready);
      expect(phases, contains(ModelLoadPhase.initializingRuntime));
      expect(phases, isNot(contains(ModelLoadPhase.failed)));
    });

    test('a failed load ends on the failed phase', () async {
      final llm = _SlowLlm()..failWith = StateError('boom');
      final scheduler = build(adapters: {'a': llm});
      addTearDown(scheduler.dispose);

      final phases = <ModelLoadPhase>[];
      final sub =
          scheduler.loadProgress('a').listen((p) => phases.add(p.phase));
      addTearDown(sub.cancel);

      await expectLater(
        scheduler.loadModel('a', preference: RuntimePreference.cpu),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      expect(phases.last, ModelLoadPhase.failed);
    });

    test('a late subscriber sees the phase already in flight', () async {
      final gate = Completer<void>();
      final scheduler = build(adapters: {'a': _SlowLlm(gate: gate)});
      addTearDown(scheduler.dispose);

      final load = scheduler.loadModel('a');
      await pumpEventQueue();

      // Subscribes only after the load has started.
      final seen = <ModelLoadProgress>[];
      final sub = scheduler.loadProgress('a').listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      expect(seen, isNotEmpty,
          reason: 'a widget mounting mid-load must render a loader');
      expect(seen.first.phase, ModelLoadPhase.initializingRuntime);

      gate.complete();
      await load;
    });

    test('phases also reach the global runtime event stream', () async {
      final scheduler = build(adapters: {'a': _SlowLlm()});
      addTearDown(scheduler.dispose);

      final events = <RuntimeEvent>[];
      final sub = scheduler.events.listen(events.add);
      addTearDown(sub.cancel);

      await scheduler.loadModel('a');
      await pumpEventQueue();

      expect(events.whereType<RuntimeModelLoadProgress>(), isNotEmpty);
      expect(events.whereType<RuntimeModelLoaded>(), hasLength(1));
      expect(events.whereType<RuntimeCompatibilityChecked>(), hasLength(1));
    });

    test('the second load of a model carries a duration estimate', () async {
      final scheduler = build(adapters: {'a': _SlowLlm()});
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      await scheduler.unloadModel('a');

      final seen = <ModelLoadProgress>[];
      final sub = scheduler.loadProgress('a').listen(seen.add);
      addTearDown(sub.cancel);

      clock.advance(const Duration(seconds: 1));
      await scheduler.loadModel('a');
      await pumpEventQueue();

      expect(seen.last.phase, ModelLoadPhase.ready);
      expect(seen.last.fraction, 1.0);
      expect(scheduler.cacheStats.lastLoadDurations.containsKey('a'), isTrue);
    });

    test('fraction is null while nothing is known about the duration', () {
      const progress = ModelLoadProgress(
        modelId: 'a',
        phase: ModelLoadPhase.initializingRuntime,
        elapsed: Duration(seconds: 3),
      );
      expect(progress.fraction, isNull);
    });

    test('fraction never reaches 1 before the load is ready', () {
      const progress = ModelLoadProgress(
        modelId: 'a',
        phase: ModelLoadPhase.initializingRuntime,
        elapsed: Duration(seconds: 30),
        expectedDuration: Duration(seconds: 3),
      );
      expect(progress.fraction, 0.99);
    });
  });

  group('pinning', () {
    test('a pinned model is not evicted to make room', () async {
      final a = _SlowLlm();
      final b = _SlowLlm();
      final c = _SlowLlm();
      final scheduler = build(
        adapters: {'a': a, 'b': b, 'c': c},
        policy: const RuntimeMemoryPolicy(maxLoadedModels: 2),
      );
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      scheduler.setPinned('a', pinned: true);
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('b');
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('c');

      expect(scheduler.isLoaded('a'), isTrue,
          reason: 'a is least-recently-used but pinned');
      expect(scheduler.isLoaded('b'), isFalse);
      expect(scheduler.isLoaded('c'), isTrue);
    });

    test('a pin set before the model loads still takes effect', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm(), 'b': _SlowLlm(), 'c': _SlowLlm()},
        policy: const RuntimeMemoryPolicy(maxLoadedModels: 2),
      );
      addTearDown(scheduler.dispose);

      // Pinned while not loaded — the old `setLocked` silently did nothing.
      scheduler.setPinned('a', pinned: true);
      await scheduler.loadModel('a');
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('b');
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('c');

      expect(scheduler.isLoaded('a'), isTrue);
      expect(scheduler.pinnedModels, {'a'});
    });

    test('unpinning makes the model evictable again', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm(), 'b': _SlowLlm(), 'c': _SlowLlm()},
        policy: const RuntimeMemoryPolicy(maxLoadedModels: 2),
      );
      addTearDown(scheduler.dispose);

      scheduler.setPinned('a', pinned: true);
      await scheduler.loadModel('a');
      scheduler.setPinned('a', pinned: false);
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('b');
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('c');

      expect(scheduler.isLoaded('a'), isFalse);
      expect(scheduler.pinnedModels, isEmpty);
    });
  });

  group('cache stats', () {
    test('a first load is a miss and a repeat is a hit', () async {
      final scheduler = build(adapters: {'a': _SlowLlm()});
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      expect(scheduler.cacheStats.misses, 1);
      expect(scheduler.cacheStats.hits, 0);

      await scheduler.loadModel('a');
      await scheduler.loadModel('a');
      expect(scheduler.cacheStats.hits, 2);
      expect(scheduler.cacheStats.hitRate, closeTo(2 / 3, 1e-9));
    });

    test('evictions are counted separately from explicit unloads', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm(), 'b': _SlowLlm()},
        policy: const RuntimeMemoryPolicy(maxLoadedModels: 1),
      );
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      await scheduler.loadModel('b');
      expect(scheduler.cacheStats.evictions, 1);

      await scheduler.unloadModel('b');
      expect(scheduler.cacheStats.evictions, 1,
          reason: 'an explicit unload is not an eviction');
    });

    test('stats report the loaded set and the policy limit', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm(), 'b': _SlowLlm()},
        policy: const RuntimeMemoryPolicy(maxLoadedModels: 3),
      );
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      await scheduler.loadModel('b');

      final stats = scheduler.cacheStats;
      expect(stats.loadedModelIds, containsAll(['a', 'b']));
      expect(stats.maxLoadedModels, 3);
      expect(stats.requests, 2);
    });
  });

  group('warm-up', () {
    test('loads every id and reports null for each success', () async {
      final scheduler = build(adapters: {'a': _SlowLlm(), 'b': _SlowLlm()});
      addTearDown(scheduler.dispose);

      final results = await scheduler.warmUp(['a', 'b']);

      expect(results, {'a': null, 'b': null});
      expect(scheduler.isLoaded('a'), isTrue);
      expect(scheduler.isLoaded('b'), isTrue);
    });

    test('one failure does not abort the rest', () async {
      final bad = _SlowLlm()..failWith = StateError('boom');
      final scheduler = build(adapters: {'a': bad, 'b': _SlowLlm()});
      addTearDown(scheduler.dispose);

      final results =
          await scheduler.warmUp(['a', 'b'], preference: RuntimePreference.cpu);

      expect(results['a'], isA<StateError>());
      expect(results['b'], isNull);
      expect(scheduler.isLoaded('b'), isTrue,
          reason: 'a failed TTS warm-up must not stop the LLM warming up');
    });
  });

  group('compatibility gate', () {
    test('a blocking issue fails the load before the adapter is touched',
        () async {
      final llm = _SlowLlm();
      final scheduler = build(
        adapters: {'a': llm},
        manifests: {
          'a': llmManifest('a', platforms: const ['ios'])
        },
      );
      addTearDown(scheduler.dispose);

      await expectLater(
        scheduler.loadModel('a'),
        throwsA(isA<IncompatibleDeviceError>()),
      );
      expect(llm.loadCount, 0, reason: 'the adapter must never be called');
      expect(scheduler.isLoaded('a'), isFalse);
    });

    test('warn enforcement reports but still loads', () async {
      final llm = _SlowLlm();
      final scheduler = build(
        adapters: {'a': llm},
        manifests: {
          'a': llmManifest('a', platforms: const ['ios'])
        },
        enforcement: CompatibilityEnforcement.warn,
      );
      addTearDown(scheduler.dispose);

      final events = <RuntimeEvent>[];
      final sub = scheduler.events.listen(events.add);
      addTearDown(sub.cancel);

      await scheduler.loadModel('a');
      await pumpEventQueue();

      expect(scheduler.isLoaded('a'), isTrue);
      final checked = events.whereType<RuntimeCompatibilityChecked>().single;
      expect(checked.report.isCompatible, isFalse);
    });

    test('off enforcement never probes the device', () async {
      var probes = 0;
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        manifests: {
          'a': llmManifest('a', platforms: const ['ios'])
        },
        enforcement: CompatibilityEnforcement.off,
        deviceProbe: () async {
          probes++;
          return _androidDevice;
        },
      );
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');

      expect(scheduler.isLoaded('a'), isTrue);
      expect(probes, 0);
    });

    test('a failing probe does not fail the load it was gating', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        deviceProbe: () async => throw StateError('no /proc/meminfo'),
      );
      addTearDown(scheduler.dispose);

      await expectLater(scheduler.loadModel('a'), completes);
      expect(scheduler.isLoaded('a'), isTrue);
    });
  });

  group('device capabilities cache', () {
    test('repeat calls inside the TTL reuse one probe', () async {
      var probes = 0;
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        deviceProbe: () async {
          probes++;
          return _androidDevice;
        },
      );
      addTearDown(scheduler.dispose);

      await scheduler.deviceCapabilities();
      await scheduler.deviceCapabilities();
      expect(probes, 1);
    });

    test('the probe runs again once the TTL expires', () async {
      var probes = 0;
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        deviceProbe: () async {
          probes++;
          return _androidDevice;
        },
      );
      addTearDown(scheduler.dispose);

      await scheduler.deviceCapabilities();
      clock.advance(const Duration(minutes: 5));
      await scheduler.deviceCapabilities();

      expect(probes, 2,
          reason: 'free RAM and free disk move while the app runs');
    });
  });

  test('memory accounting falls back to the weight size', () async {
    final scheduler = build(
      adapters: {'a': _SlowLlm()},
      manifests: {'a': llmManifest('a', sizeBytes: 500 * 1024 * 1024)},
    );
    addTearDown(scheduler.dispose);

    await scheduler.loadModel('a');

    expect(scheduler.memoryUsage.modelBytes, 500 * 1024 * 1024);
    expect(scheduler.memoryUsage.totalBytes, 8192 * 1024 * 1024,
        reason: 'the probed device total must reach memoryUsage');
  });

  test('adapter() names both types when the provider is mis-registered',
      () async {
    final scheduler = build(adapters: {'a': _SlowLlm()});
    addTearDown(scheduler.dispose);

    await scheduler.loadModel('a');

    expect(
      () => scheduler.adapter<LocalStt>('a'),
      throwsA(isA<InvalidStateError>().having(
        (e) => e.message,
        'message',
        allOf(contains('LocalStt'), contains('wrong adapter capability')),
      )),
    );
  });

  group('review follow-ups', () {
    test('unpinning does not release a session lock', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm(), 'b': _SlowLlm(), 'c': _SlowLlm()},
        policy: const RuntimeMemoryPolicy(maxLoadedModels: 2),
      );
      addTearDown(scheduler.dispose);

      await scheduler.loadModel('a');
      scheduler.setPinned('a', pinned: true);
      // A voice session locks the same model for its lifetime.
      scheduler.setLocked('a', locked: true);
      scheduler.setPinned('a', pinned: false);

      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('b');
      clock.advance(const Duration(minutes: 1));
      await scheduler.loadModel('c');

      expect(scheduler.isLoaded('a'), isTrue,
          reason: 'the session lock outlives the pin');
      expect(scheduler.pinnedModels, isEmpty);
    });

    test('a joined load counts as a miss for the joiner too', () async {
      final gate = Completer<void>();
      final scheduler = build(adapters: {'a': _SlowLlm(gate: gate)});
      addTearDown(scheduler.dispose);

      final first = scheduler.loadModel('a');
      final second = scheduler.loadModel('a');
      final third = scheduler.loadModel('a');
      await pumpEventQueue();
      gate.complete();
      await Future.wait([first, second, third]);

      expect(scheduler.cacheStats.misses, 3,
          reason: 'all three callers waited for the load');
      expect(scheduler.cacheStats.hits, 0);
    });

    test('a full disk does not make an installed model unloadable', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        manifests: {'a': llmManifest('a', sizeBytes: 2048 * 1024 * 1024)},
        deviceProbe: () async => const DeviceCapabilities(
          totalMemoryMB: 8192,
          availableMemoryMB: 6144,
          freeDiskMB: 10, // nowhere near the download budget
          platform: 'android',
        ),
      );
      addTearDown(scheduler.dispose);

      await expectLater(scheduler.loadModel('a'), completes);
      expect(scheduler.isLoaded('a'), isTrue);
    });

    test('the load gate still enforces RAM', () async {
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        manifests: {'a': llmManifest('a', minMemoryMB: 6000)},
        deviceProbe: () async => const DeviceCapabilities(
          totalMemoryMB: 2048,
          availableMemoryMB: 1024,
          freeDiskMB: 65536,
          platform: 'android',
        ),
      );
      addTearDown(scheduler.dispose);

      await expectLater(
        scheduler.loadModel('a'),
        throwsA(isA<IncompatibleDeviceError>()),
      );
    });

    test('a probe failure does not make the device look CPU-only', () async {
      final manifest = LocalModelManifest(
        id: 'a',
        type: ModelType.llm,
        provider: 'test-provider',
        delivery: ModelDelivery.download,
        platforms: const ['android'],
        requiredAccelerators: const {Accelerator.gpu},
        files: const [
          ModelFile(
            name: 'a.bin',
            url: 'https://example.invalid/a.bin',
            sha256: kPlaceholderSha256,
            sizeBytes: 0,
          ),
        ],
      );
      final scheduler = build(
        adapters: {'a': _SlowLlm()},
        manifests: {'a': manifest},
        deviceProbe: () async => throw StateError('probe unavailable'),
      );
      addTearDown(scheduler.dispose);

      await expectLater(scheduler.loadModel('a'), completes,
          reason: 'a transient probe error must not block a GPU model');
      expect(scheduler.isLoaded('a'), isTrue);
    });
  });
}
