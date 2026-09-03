/// One-line registration of the llama.cpp adapters (architecture §4.5).
library;

import 'package:local_ai_core/local_ai_core.dart';

import 'llama_cpp_embedding_adapter.dart';
import 'llama_cpp_llm_adapter.dart';

/// Registers the llama.cpp LLM **and** embedding factories under the
/// `llama-cpp` provider key.
///
/// ```dart
/// await LocalAI.initialize(config, plugins: [LlamaCppAdapterPlugin()]);
/// ```
///
/// Both capabilities are registered together because they share one native
/// library; a model manifest picks which one it needs through its
/// `ModelType`, and an unused capability costs nothing until a manifest
/// resolves to it (no isolate is spawned and no model is loaded).
class LlamaCppAdapterPlugin implements AdapterPlugin {
  const LlamaCppAdapterPlugin();

  @override
  void register(AdapterRegistry registry) {
    registry.registerLlm(
      ModelProviders.llamaCpp,
      (context) => LlamaCppLlmAdapter(paths: context.paths),
    );
    registry.registerEmbedding(
      ModelProviders.llamaCpp,
      (context) => LlamaCppEmbeddingAdapter(paths: context.paths),
    );
  }
}
