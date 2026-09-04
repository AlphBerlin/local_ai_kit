# Runtime & Memory

`ai.runtime` (`RuntimeScheduler`, implementing `LocalModelRuntime`) coordinates model loading across all capabilities with an LRU memory policy, backend fallback and device probing.

## RuntimePreference

| Value | Meaning |
|---|---|
| `auto` | Let the adapter pick the best available backend (default). |
| `cpu` | CPU only — most compatible, slowest. |
| `gpu` | GPU delegate (OpenCL / Metal). |
| `npu` | NPU / NNAPI / Neural Engine. |

Set a global default via `LocalAIConfig.runtimePreference`, or per component via `LlmConfig.runtime`. If a `gpu`/`npu` load fails, the scheduler automatically falls back to `cpu` and reports it as `RuntimeBackendFallback` on the events stream.

## RuntimeMemoryPolicy

```dart
const policy = RuntimeMemoryPolicy(
  unloadUnusedAfter: Duration(minutes: 5), // idle sweep timeout
  maxLoadedModels: 2,                      // LRU cap
  trimOnBackground: true,                  // unload when app backgrounds
);

// Conservative variant for low-RAM devices:
const lowMem = RuntimeMemoryPolicy.lowMemory();
// → unloadUnusedAfter: 2 min, maxLoadedModels: 1, trimOnBackground: true
```

How the scheduler applies it:

- Every `LoadedModel` tracks `lastUsedAt`; any generate/transcribe/speak call refreshes it (`touch`).
- Loading a new model while `loadedModels.length >= maxLoadedModels` evicts the least-recently-used **unlocked** model first.
- A periodic sweep (every 30 s by default, configurable via `RuntimeScheduler`'s `sweepInterval`) unloads models idle longer than `unloadUnusedAfter`.
- When the app goes to background and `trimOnBackground` is true, all unlocked models are unloaded (`reason: 'backgroundTrim'`).
- Models locked by an active voice session (`setLocked`) are never evicted.
- `ai.runtime.dispose()` (called by `LocalAI.dispose()`) stops the sweep timer and unloads every loaded model, locked or not.

## load / unload / inspect

```dart
// Explicit control (facades do this lazily for you):
await ai.runtime.loadModel(Models.gemma3nE2b.id,
    preference: RuntimePreference.gpu);
await ai.runtime.unloadModel(Models.gemma3nE2b.id);

// Inspection:
for (final m in ai.runtime.loadedModels) {
  print('${m.modelId} on ${m.backend.name}, '
      'last used ${m.lastUsedAt}, locked=${m.locked}');
}
final usage = ai.runtime.memoryUsage;
print('${(usage.usedFraction * 100).toStringAsFixed(0)}% used, '
    'models hold ~${usage.modelBytes ~/ (1024 * 1024)} MB');
```

`LoadedModel` fields: `modelId`, `type`, `backend` (effective backend after fallback), `loadedAt`, `lastUsedAt`, `locked`, `estimatedBytes`.

## RuntimeEvent stream

```dart
ai.runtime.events.listen((event) {
  switch (event) {
    case RuntimeModelLoaded(:final model):
      print('loaded ${model.modelId}');
    case RuntimeModelUnloaded(:final modelId, :final reason):
      // reason: evicted / idle / explicit / backgroundTrim
      print('unloaded $modelId ($reason)');
    case RuntimeBackendFallback(:final modelId, :final requested, :final effective):
      print('$modelId: $requested → $effective');
    case RuntimeMemoryPressure(:final usage):
      print('memory pressure: ${usage.usedFraction}');
  }
});
```

## Device capabilities & compatibility

```dart
final caps = await ai.runtime.deviceCapabilities();
// caps.totalMemoryMB, availableMemoryMB, freeDiskMB, platform,
// socModel, accelerators: {cpu, gpu, nnapi, neuralEngine, metal}

final manifest = await ai.catalog.get(Models.gemma3nE2b.id);
final report = await ai.runtime.checkCompatibility(manifest);
if (!report.isCompatible) {
  // report.reasons, report.availableMemoryMB, report.requiredMemoryMB
  print(report.summary);
}
```

`ai.models.checkCompatibility(modelId)` is the same check by id, and `ai.models.compatible(type: ModelType.llm)` returns the catalog already filtered for this device — that is what a model-picker screen wants.

The default probe is `FlutterDeviceProbe`, wired automatically by `LocalAI.initialize`; inject your own with `LocalAI.initialize(deviceProbe: …)`. Tests should always inject one, otherwise they assert against whatever host runs them.

`isCompatible` answers only the blocking question. A compatible report can still carry `warnings` worth showing — tight RAM, a CPU-only fallback, a context window that will be clamped:

```dart
if (!report.isCompatible) {
  showBlocked(report.summary);                 // report.blockers
} else if (report.hasWarnings) {
  showAdvisory(report.warnings.map((i) => i.message));
}
```

Each `CompatibilityIssue` carries a `check` (`platform`, `totalMemory`, `availableMemory`, `disk`, `accelerator`, `contextWindow`, `unknown`), a `severity`, and `requiredMB` / `availableMB` for the capacity checks. A metric the probe could not read is reported as a `unknown` warning naming the skipped check — never as a pass or a fail.

### Enforcement

`install`, `ensureInstalled` and `loadModel` run the check themselves and throw `IncompatibleDeviceError` (carrying the report) on a blocking issue. `LocalAIConfig.compatibilityEnforcement` changes that:

| Value | Behaviour |
|---|---|
| `enforce` (default) | Throws before the download starts and before the model loads |
| `warn` | Reports through `RuntimeCompatibilityChecked` on `ai.runtime.events`, never fails a call |
| `off` | No probe, no check |

`LocalAIConfig.compatibilityPolicy` tunes the thresholds — `ModelCompatibilityPolicy.strict()` also blocks on a momentary RAM shortfall, `.permissive()` blocks on nothing but platform and required accelerators.

**On Linux and Windows this check is strict for a real reason:** most catalog manifests list `['android', 'ios', 'macos']`, so they are genuinely reported incompatible there. The GGUF models served by `local_ai_llama_cpp` do list desktop platforms.

## Loading: phases, warm-up and pinning

Loading a multi-gigabyte model is the longest blocking step in a local-AI app, so it is observable rather than a `Future` you wait on blind.

```dart
StreamBuilder<ModelLoadProgress>(
  stream: ai.runtime.loadProgress(modelId),
  builder: (context, snapshot) {
    final p = snapshot.data;
    if (p == null || p.phase == ModelLoadPhase.ready) return const ChatView();
    return LinearProgressIndicator(value: p.fraction);
  },
);
```

Phases run `queued → evicting → openingFiles → initializingRuntime → warmingUp → ready`, or `failed` from any of them. `loadProgress` replays the current phase to a late subscriber, so a widget that mounts mid-load renders a loader rather than a blank screen. The same transitions reach `ai.runtime.events` as `RuntimeModelLoadProgress` for a global "loading models…" banner.

`fraction` is `null` on a model's **first** load — nothing is known yet about how long it takes on this device, so render an indeterminate indicator. From the second load on it is computed against `expectedDuration`, the previous measured load time, and clamped to `0.99` while running.

Concurrent requests for the same model share one load: N callers produce one native initialization, not N.

```dart
// Load ahead of first use; a failure on one model does not abort the rest.
final results = await ai.warmUp();          // every configured model
// or from the start, in the background:
LocalAIConfig(warmUpOnInitialize: true);

// Keep one model resident against the LRU policy, the idle sweep and the
// background trim.
ai.pinModel(llmModelId);
ai.unpinModel(llmModelId);
```

## Cache statistics

`maxLoadedModels` and `unloadUnusedAfter` are two numbers with no obvious right value. `ai.runtime.cacheStats` is how you find out whether yours are wrong:

```dart
final stats = ai.runtime.cacheStats;
stats.hits;                // requests served without a load
stats.misses;              // requests that waited for one
stats.hitRate;             // hits / (hits + misses)
stats.evictions;           // unloaded to make room
stats.idleUnloads;         // unloaded by the sweep or a background trim
stats.lastLoadDurations;   // what each miss actually costs, per model
```

A high `missRate` together with many `evictions` over a small set of ids is thrashing: `maxLoadedModels` is too low for the app's access pattern, and `lastLoadDurations` prices each miss in seconds the user waits.
