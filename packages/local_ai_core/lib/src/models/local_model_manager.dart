/// Download/install management interface (architecture §4.2).
library;

import 'dart:async';
import 'model_status.dart';

/// Per-download behavior switches.
class DownloadPolicy {
  const DownloadPolicy({
    this.wifiOnly = true,
    this.maxRetries = 5,
    this.verifySha256 = true,
  });

  /// Only download over Wi-Fi; on cellular the download stays `queued`
  /// until Wi-Fi returns (see `NetworkPolicy.onStatusChanged`).
  final bool wifiOnly;

  /// Max network retries with exponential backoff (1s/2s/4s, cap 30s).
  final int maxRetries;

  /// Verify per-file sha256 after download (recommended; disabling is only
  /// for debugging).
  final bool verifySha256;
}

/// Manages the on-device lifecycle of model artifacts.
///
/// Implemented by `ModelManagerImpl` in `local_ai_kit`.
abstract interface class LocalModelManager {
  /// Whether [modelId] is fully installed and verified.
  Future<bool> isInstalled(String modelId);

  /// Point-in-time status.
  Future<ModelStatus> getStatus(String modelId);

  /// Idempotent: returns immediately when the model is installed and passes
  /// verification; otherwise queues/starts the download.
  Future<void> ensureInstalled(
    String modelId, {
    DownloadPolicy policy = const DownloadPolicy(),
  });

  /// Downloads and installs [modelId] even if already installed (reinstall).
  Future<void> install(String modelId, {DownloadPolicy? policy});

  /// Upgrades to a newer catalog version when available.
  Future<void> update(String modelId);

  /// Deletes the installed files and download scratch data.
  Future<void> remove(String modelId);

  /// Full sha256 re-verification of the installed files.
  Future<bool> verify(String modelId);

  /// Live download progress for [modelId] (broadcast).
  Stream<ModelDownloadProgress> downloadProgress(String modelId);

  /// Status changes for [modelId] (broadcast).
  Stream<ModelStatus> watchStatus(String modelId);
}