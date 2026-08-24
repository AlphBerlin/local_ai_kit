/// One-line registration of the Gemma adapter (architecture §4.5).
library;

import 'package:local_ai_core/local_ai_core.dart';

import 'gemma_llm_adapter.dart';

/// Registers the Gemma LLM factory into an [AdapterRegistry].
///
/// ```dart
/// await LocalAI.initialize(config, plugins: [GemmaAdapterPlugin()]);
/// ```
class GemmaAdapterPlugin implements AdapterPlugin {
  const GemmaAdapterPlugin();

  @override
  void register(AdapterRegistry registry) {
    registry.registerLlm(
      ModelProviders.googleGemma,
      (context) => GemmaLlmAdapter(paths: context.paths),
    );
  }
}
