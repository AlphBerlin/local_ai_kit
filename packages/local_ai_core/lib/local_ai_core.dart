/// LocalAI Kit core: pure-Dart capability interfaces, configuration models,
/// model manifests, state/event models, adapter registry and test fakes.
///
/// This package intentionally has **no** Flutter / flutter_gemma / genkit /
/// sherpa_onnx dependencies (architecture §2 rule 1).
library;

// Audio primitives
export 'src/audio/audio_chunk.dart';
export 'src/audio/audio_frame.dart';
export 'src/audio/local_audio_output.dart';
export 'src/audio/local_audio_source.dart';

// Catalog
export 'src/catalog/local_model_catalog.dart';

// Common
export 'src/common/cancel_token.dart';
export 'src/common/clock.dart';
export 'src/common/local_storage_paths.dart';
export 'src/common/network_policy.dart';

// Config
export 'src/config/component_configs.dart';
export 'src/config/local_ai_config.dart';

// Embedding
export 'src/embedding/local_embedding.dart';

// Errors
export 'src/errors/local_ai_error.dart';

// LLM
export 'src/llm/json_schema.dart';
export 'src/llm/llm_request.dart';
export 'src/llm/local_llm.dart';
export 'src/llm/orchestrator.dart';
export 'src/llm/structured_output.dart';

// Models
export 'src/models/device_capabilities.dart';
export 'src/models/local_model_manager.dart';
export 'src/models/local_voice.dart';
export 'src/models/manifest.dart';
export 'src/models/model_compatibility.dart';
export 'src/models/model_delivery.dart';
export 'src/models/model_file.dart';
export 'src/models/model_status.dart';
export 'src/models/models.dart';

// Pipeline / voice events
export 'src/pipeline/pipeline_event.dart';
export 'src/pipeline/voice_event.dart';
export 'src/pipeline/voice_session_config.dart';

// Plugins / MCP / Skills
export 'src/plugins/builtin_skills.dart';
export 'src/plugins/mcp_plugin.dart';
export 'src/plugins/mcp_types.dart';
export 'src/plugins/skill_executor.dart';
export 'src/plugins/skill_registry.dart';

// Registry
export 'src/registry/adapter_registry.dart';

// Runtime
export 'src/runtime/local_model_runtime.dart';
export 'src/runtime/memory_policy.dart';
export 'src/runtime/model_load_progress.dart';

// STT
export 'src/stt/local_stt.dart';
export 'src/stt/transcript.dart';
export 'src/stt/transcript_cleanup.dart';

// Testing fakes
export 'src/testing/fake_llm.dart';
export 'src/testing/fake_stt.dart';
export 'src/testing/fake_tts.dart';
export 'src/testing/fake_vad.dart';

// TTS
export 'src/tts/local_tts.dart';

// VAD
export 'src/vad/local_vad.dart';
