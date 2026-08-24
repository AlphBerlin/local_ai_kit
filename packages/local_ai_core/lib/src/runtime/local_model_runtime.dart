/// Runtime lifecycle interface: loading, unloading, capability checks.
library;

import 'dart:async';
import '../models/device_capabilities.dart';
import '../models/manifest.dart';
import 'memory_policy.dart';

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
}
