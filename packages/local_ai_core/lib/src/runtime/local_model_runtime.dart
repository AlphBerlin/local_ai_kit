/// Runtime lifecycle interface: loading, unloading, capability checks.
library;

import 'dart:async';
import '../models/device_capabilities.dart';
import '../models/manifest.dart';
import 'memory_policy.dart';
import 'model_load_progress.dart';

/// A model currently held in memory by the runtime.
class LoadedModel {
  const LoadedModel({
    required this.modelId,
    required this.type,
    required this.backend,
    required this.loadedAt,
    required this.lastUsedAt,
    this.locked = false,
    this.estimatedBytes = 0,
  });

  final String modelId;
  final ModelType type;

  /// Effective backend in use (may differ from the requested
  /// [RuntimePreference] after fallback).
  final RuntimePreference backend;
  final DateTime loadedAt;
  final DateTime lastUsedAt;

  /// Locked models (e.g. components of an active voice session) are never
  /// evicted by the LRU policy.
  final bool locked;

  /// Best-effort RSS estimate of this model.
  final int estimatedBytes;

  LoadedModel copyWith({
    DateTime? lastUsedAt,
    bool? locked,
    int? estimatedBytes,
  }) {
    return LoadedModel(
      modelId: modelId,
      type: type,
      backend: backend,
      loadedAt: loadedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      locked: locked ?? this.locked,
      estimatedBytes: estimatedBytes ?? this.estimatedBytes,
    );
  }
}

/// Runtime lifecycle events.
sealed class RuntimeEvent {
  const RuntimeEvent();
}

final class RuntimeModelLoaded extends RuntimeEvent {
  const RuntimeModelLoaded(this.model);
  final LoadedModel model;
}

final class RuntimeModelUnloaded extends RuntimeEvent {
  const RuntimeModelUnloaded(this.modelId, {required this.reason});
  final String modelId;

  /// `evicted` / `idle` / `explicit` / `backgroundTrim`.
  final String reason;
}

/// The requested backend failed and the runtime fell back to a weaker one.
final class RuntimeBackendFallback extends RuntimeEvent {
  const RuntimeBackendFallback({
    required this.modelId,
    required this.requested,
    required this.effective,
    this.reason,
  });

  final String modelId;
  final RuntimePreference requested;
  final RuntimePreference effective;
  final String? reason;
}

/// Memory pressure detected; the scheduler is about to evict models.
final class RuntimeMemoryPressure extends RuntimeEvent {
  const RuntimeMemoryPressure(this.usage);
  final MemoryUsage usage;
}

/// A model load moved to a new phase.
///
/// Emitted for every phase transition of every load, so one listener on
/// [LocalModelRuntime.events] can drive a global "loading models…" banner;
/// use [LocalModelRuntime.loadProgress] for a single model.
final class RuntimeModelLoadProgress extends RuntimeEvent {
  const RuntimeModelLoadProgress(this.progress);
  final ModelLoadProgress progress;
}

/// A model was checked against the device before loading or downloading.
///
/// Emitted whether or not the check passed, so an app can surface
/// warnings ("RAM is tight") without polling.
final class RuntimeCompatibilityChecked extends RuntimeEvent {
  const RuntimeCompatibilityChecked({
    required this.modelId,
    required this.report,
  });

  final String modelId;
  final CompatibilityReport report;
}

/// Coordinates model loading across capabilities with an LRU memory policy.
///
/// Implemented by `RuntimeScheduler` in `local_ai_kit`.
abstract interface class LocalModelRuntime {
  /// Loads [modelId], applying the memory policy (evicting LRU models when
  /// necessary). Falls back from npu/gpu to cpu on backend failure and
  /// reports it via [events].
  Future<void> loadModel(String modelId, {RuntimePreference? preference});

  /// Unloads [modelId] if loaded. No-op otherwise.
  Future<void> unloadModel(String modelId);

  /// Currently loaded models.
  List<LoadedModel> get loadedModels;

  /// Current memory accounting.
  MemoryUsage get memoryUsage;

  /// Probes the device.
  Future<DeviceCapabilities> deviceCapabilities();

  /// Checks whether [manifest] can run on this device.
  Future<CompatibilityReport> checkCompatibility(LocalModelManifest manifest);

  /// Lifecycle events stream (broadcast).
  Stream<RuntimeEvent> get events;

  /// Phase-by-phase progress of loads of [modelId] (broadcast).
  ///
  /// Emits the current phase immediately to a new listener when a load is
  /// already in flight, so a widget that subscribes late still renders a
  /// loader instead of a blank screen.
  Stream<ModelLoadProgress> loadProgress(String modelId);

  /// Loads [modelIds] ahead of first use so the first `generate` /
  /// `transcribe` call does not pay the load cost.
  ///
  /// Loads run sequentially (concurrent native loads compete for the same
  /// memory) and a failure on one id does not abort the rest — the
  /// returned map reports the outcome per id.
  Future<Map<String, Object?>> warmUp(
    List<String> modelIds, {
    RuntimePreference? preference,
  });

  /// Pins [modelId] so the LRU policy, the idle sweep and the background
  /// trim never unload it.
  ///
  /// Unlike locking a loaded model, a pin survives across loads: pinning an
  /// id that is not loaded yet takes effect the moment it is.
  void setPinned(String modelId, {required bool pinned});

  /// Ids currently pinned.
  Set<String> get pinnedModels;

  /// Cache effectiveness counters, for diagnostics and for tuning
  /// `RuntimeMemoryPolicy.maxLoadedModels`.
  ModelCacheStats get cacheStats;
}
