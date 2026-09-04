/// llama.cpp adapter for LocalAI Kit.
///
/// Runs any GGUF model through llama.cpp behind the core [LocalLlm] and
/// [LocalEmbedding] interfaces. All `llama_cpp_dart` types stay inside this
/// package (architecture §2 rule 2) and every native call happens in a
/// worker isolate.
///
/// ```dart
/// final ai = await LocalAI.initialize(
///   const LocalAIConfig(llm: LlmConfig(modelId: 'qwen-2.5-0.5b-instruct-gguf')),
///   plugins: const [LlamaCppAdapterPlugin()],
/// );
/// ```
library;

export 'src/backend_selection.dart';
export 'src/chat_template.dart';
export 'src/context_window.dart';
export 'src/embedding_vectors.dart';
export 'src/gguf_locator.dart';
export 'src/isolate/llama_worker_protocol.dart'
    show SamplerSpec, LlamaStopReason;
export 'src/json_schema_to_gbnf.dart';
export 'src/llama_cpp_adapter_plugin.dart';
export 'src/llama_cpp_embedding_adapter.dart';
export 'src/llama_cpp_llm_adapter.dart';
export 'src/llama_cpp_runtime.dart';
export 'src/prompt_plan.dart';
export 'src/stop_sequences.dart';
