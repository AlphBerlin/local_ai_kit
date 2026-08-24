/// Storage layout abstraction for model artifacts.
library;

import 'dart:async';
import '../models/manifest.dart';

/// Resolves the on-disk layout used by the model manager.
///
/// Canonical layout (see docs-internal/architecture.md §5.1):
/// ```
/// <rootDir>/                       e.g. <app-support>/local_ai
///   models/{llm,stt,vad,tts,embedding}/<modelId>/   (contains installed.json)
///   voices/<voiceId>/
///   manifests/catalog.remote.json, catalog.merged.json
///   downloads/<modelId>/           temporary; removed after install
///   cache/                         KV cache, temp audio; OS may purge
/// ```
///
/// `downloads/` and `models/` MUST live under the same root so that the
/// final install step is an atomic same-partition rename.
abstract interface class LocalStoragePaths {
  /// Root directory of all LocalAI data.
  String get rootDir;

  /// Directory where installed models live, grouped by [ModelType].
  String get modelsDir;

  /// Directory for one installed model: `models/<type>/<modelId>`.
  String modelDir(ModelType type, String modelId);

  /// Directory for in-progress downloads (atomic-rename source).
  String get downloadsDir;

  /// Download scratch directory for one model: `downloads/<modelId>`.
  String downloadDir(String modelId);

  /// Directory where TTS voices are installed independently of models.
  String get voicesDir;

  /// Directory for one installed voice: `voices/<voiceId>`.
  String voiceDir(String voiceId);

  /// Directory holding cached remote/merged catalogs.
  String get manifestsDir;

  /// Purgeable cache directory (KV cache, temp audio).
  String get cacheDir;

  /// Creates all directories above if they do not exist yet.
  Future<void> ensureInitialized();
}