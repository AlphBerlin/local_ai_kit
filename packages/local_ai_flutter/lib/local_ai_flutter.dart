/// LocalAI Kit Flutter platform layer.
///
/// Implements the core abstractions (`LocalStoragePaths`, `LocalAudioSource`,
/// `LocalAudioOutput`, `NetworkPolicy`, ...) on top of Flutter plugins.
library;

export 'src/audio_player.dart';
export 'src/audio_recorder.dart';
export 'src/device_probe.dart';
export 'src/device_metrics_source.dart';
export 'src/lifecycle_observer.dart';
export 'src/network_policy.dart';
export 'src/permission_gate.dart';
export 'src/storage_paths.dart';
