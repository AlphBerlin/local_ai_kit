/// Observable model loading: phases, progress and cache accounting.
///
/// Loading a multi-gigabyte model is the longest blocking step in a
/// local-AI app and, before this, the only thing an app could observe was
/// "the Future has not completed yet". These types let a UI show a real
/// loader — which phase, how long it has been running, and (once the model
/// has been loaded at least once) how long it usually takes.
library;

/// Where a model load currently is.
///
/// Order is monotonic for a successful load:
/// `queued → evicting → openingFiles → initializingRuntime → warmingUp →
/// ready`. A failure lands on [failed] from any phase.
enum ModelLoadPhase {
  /// Accepted, waiting behind another load of the same model.
  queued,

  /// Making room: the LRU policy is unloading another model first.
  evicting,

  /// Resolving and opening the installed weight files.
  openingFiles,

  /// The adapter is building its native runtime (the long phase).
  initializingRuntime,

  /// Optional adapter-side warm-up (graph build, first token).
  warmingUp,

  /// Loaded and usable.
  ready,

  /// The load failed; see the surrounding error.
  failed,
}

/// A point-in-time snapshot of one model load.
class ModelLoadProgress {
  const ModelLoadProgress({
    required this.modelId,
    required this.phase,
    required this.elapsed,
    this.expectedDuration,
    this.detail,
  });

  final String modelId;
  final ModelLoadPhase phase;

  /// Time since the load started.
  final Duration elapsed;

  /// How long this model took the last time it was loaded on this device,
  /// when known. Lets a UI show a determinate progress bar on the second
  /// and later loads instead of an indeterminate spinner.
  final Duration? expectedDuration;

  /// Free-form phase detail (file name, backend name, fallback reason).
  final String? detail;

  /// Fraction in `[0, 1]` derived from [elapsed] against
  /// [expectedDuration]; `null` on a first load, when nothing is known
  /// about how long this takes.
  ///
  /// Clamped to `0.99` while the load is still running so the bar never
  /// sits at 100% waiting, and pinned to `1` once the phase is
  /// [ModelLoadPhase.ready].
  double? get fraction {
    if (phase == ModelLoadPhase.ready) return 1;
    final expected = expectedDuration;
    if (expected == null || expected.inMicroseconds <= 0) return null;
    final ratio = elapsed.inMicroseconds / expected.inMicroseconds;
    return ratio.clamp(0.0, 0.99).toDouble();
  }

  bool get isTerminal =>
      phase == ModelLoadPhase.ready || phase == ModelLoadPhase.failed;

  @override
  String toString() => 'ModelLoadProgress($modelId, ${phase.name}, '
      '${elapsed.inMilliseconds}ms)';
}

/// Counters describing how well the in-memory model cache is working.
///
/// A high [missRate] with many [evictions] on the same two model ids means
/// the app is thrashing: `RuntimeMemoryPolicy.maxLoadedModels` is too low
/// for its access pattern, and every "miss" is a multi-second reload the
/// user waits through.
class ModelCacheStats {
  const ModelCacheStats({
    required this.loadedModelIds,
    required this.maxLoadedModels,
    required this.hits,
    required this.misses,
    required this.evictions,
    required this.idleUnloads,
    required this.lastLoadDurations,
  });

  const ModelCacheStats.empty()
      : loadedModelIds = const [],
        maxLoadedModels = 0,
        hits = 0,
        misses = 0,
        evictions = 0,
        idleUnloads = 0,
        lastLoadDurations = const {};

  /// Ids currently resident in memory.
  final List<String> loadedModelIds;

  /// The active `RuntimeMemoryPolicy.maxLoadedModels`.
  final int maxLoadedModels;

  /// Requests served by an already-loaded model (no wait).
  final int hits;

  /// Requests that had to load the model first (the user waited).
  final int misses;

  /// Models unloaded to make room for another one.
  final int evictions;

  /// Models unloaded by the idle sweep or a background trim.
  final int idleUnloads;

  /// Most recent measured load duration per model id.
  final Map<String, Duration> lastLoadDurations;

  int get requests => hits + misses;

  /// Share of requests that did not wait for a load, in `[0, 1]`.
  double get hitRate => requests == 0 ? 0 : hits / requests;

  double get missRate => requests == 0 ? 0 : misses / requests;

  /// Total time users spent waiting on loads that a warmer cache would
  /// have avoided (sum of the last measured duration per evicted model is
  /// not tracked; this sums the known durations of currently-known models).
  Duration get slowestLoad => lastLoadDurations.values.fold(
        Duration.zero,
        (slowest, d) => d > slowest ? d : slowest,
      );

  @override
  String toString() => 'ModelCacheStats(loaded=${loadedModelIds.length}/'
      '$maxLoadedModels, hitRate=${(hitRate * 100).toStringAsFixed(0)}%, '
      'evictions=$evictions)';
}
