/// Model install status and download progress models.
library;

import '../errors/local_ai_error.dart';

/// Full install state machine (architecture §5.1).
///
/// Happy path (single direction, retry may step back):
/// `notInstalled → queued → downloading ⇄ paused → verifying → extracting
/// → installing → installed → loading → ready`.
/// Any state may transition to `failed`; `installed → updating` on catalog
/// upgrades.
enum ModelInstallState {
  notInstalled,
  queued,
  downloading,
  paused,
  verifying,
  extracting,
  installing,
  installed,
  loading,
  ready,
  updating,
  failed,
}

/// Point-in-time status of one model.
class ModelStatus {
  const ModelStatus({
    required this.modelId,
    required this.state,
    this.installedCatalogVersion,
    this.progress,
    this.error,
  });

  final String modelId;
  final ModelInstallState state;

  /// `catalogVersion` of the installed copy (from `installed.json`).
  final int? installedCatalogVersion;

  /// Live download progress when [state] is `downloading` / `paused`.
  final ModelDownloadProgress? progress;

  /// Failure detail when [state] is `failed`.
  final LocalAIError? error;

  bool get isInstalled =>
      state == ModelInstallState.installed ||
      state == ModelInstallState.loading ||
      state == ModelInstallState.ready;

  ModelStatus copyWith({
    ModelInstallState? state,
    int? installedCatalogVersion,
    ModelDownloadProgress? progress,
    LocalAIError? error,
  }) {
    return ModelStatus(
      modelId: modelId,
      state: state ?? this.state,
      installedCatalogVersion:
          installedCatalogVersion ?? this.installedCatalogVersion,
      progress: progress ?? this.progress,
      error: error ?? this.error,
    );
  }

  @override
  String toString() => 'ModelStatus($modelId, ${state.name})';
}

/// Live progress of a model download (architecture §5.1.6).
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.modelId,
    required this.state,
    required this.receivedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
    this.eta,
    this.currentFile,
  });

  final String modelId;
  final ModelInstallState state;
  final int receivedBytes;
  final int totalBytes;

  /// Smoothed throughput.
  final int bytesPerSecond;

  /// Estimated time remaining; `null` when unknown.
  final Duration? eta;

  /// Name of the file currently being downloaded.
  final String? currentFile;

  /// Completion ratio in [0, 1]; 0 when [totalBytes] is unknown.
  double get fraction => totalBytes > 0 ? receivedBytes / totalBytes : 0.0;

  ModelDownloadProgress copyWith({
    ModelInstallState? state,
    int? receivedBytes,
    int? totalBytes,
    int? bytesPerSecond,
    Duration? eta,
    String? currentFile,
  }) {
    return ModelDownloadProgress(
      modelId: modelId,
      state: state ?? this.state,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      eta: eta ?? this.eta,
      currentFile: currentFile ?? this.currentFile,
    );
  }

  @override
  String toString() =>
      'ModelDownloadProgress($modelId, ${(fraction * 100).toStringAsFixed(1)}%)';
}
