/// LocalAI Kit: pluggable, offline-first, streaming-first on-device AI.
///
/// Re-exports the core API so apps only need this one import plus the
/// adapter packages they use:
/// ```dart
/// import 'package:local_ai_kit/local_ai_kit.dart';
/// import 'package:local_ai_gemma/local_ai_gemma.dart';
/// import 'package:local_ai_sherpa/local_ai_sherpa.dart';
/// ```
library;

// Core API (interfaces, config, manifests, events, errors, fakes).
export 'package:local_ai_core/local_ai_core.dart';

// Platform layer (storage paths, recorder, player, probes).
export 'package:local_ai_flutter/local_ai_flutter.dart';

// Kit implementation.
export 'src/catalog/catalog_merger.dart';
export 'src/catalog/catalog_service.dart';
export 'src/catalog/remote_catalog_loader.dart';
export 'src/download/download_manager.dart';
export 'src/download/installer.dart';
export 'src/download/model_manager_impl.dart';
export 'src/download/resume_meta.dart';
export 'src/facade/facades.dart';
export 'src/facade/local_ai.dart';
export 'src/facade/model_hub.dart';
export 'src/pipeline/local_pipeline.dart';
export 'src/pipeline/presets.dart';
export 'src/runtime/runtime_scheduler.dart';
export 'src/voice/voice_pipeline.dart';
