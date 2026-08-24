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
- A periodic sweep unloads models idle longer than `unloadUnusedAfter`.
- When the app goes to background and `trimOnBackground` is true, all unlocked models are unloaded (`reason: 'backgroundTrim'`).
- Models locked by an active voice session (`setLocked`) are never evicted.

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

Use `checkCompatibility` to gate download UI: hide or annotate models whose `minMemoryMB` exceeds available RAM, or whose `platforms` exclude the current device. The default probe is `FlutterDeviceProbe`; inject your own via `LocalAI.initialize(deviceProbe: …)`.
