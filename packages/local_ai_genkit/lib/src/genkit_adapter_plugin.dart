/// Registration plugin + the `ai.genkit` escape hatch (architecture §3.5).
library;

import 'package:local_ai_core/local_ai_core.dart';

import 'genkit_llm_adapter.dart';

/// Wraps whichever LLM adapter resolves for a manifest with the Genkit
/// orchestration layer.
///
/// Registration order matters: register the base adapter plugin (e.g.
/// `GemmaAdapterPlugin`) first, then this plugin with the same provider id
/// to take over LLM resolution with the decorated adapter:
/// ```dart
/// await LocalAI.initialize(
///   config,
///   plugins: [GemmaAdapterPlugin(), GenkitAdapterPlugin()],
/// );
/// ```
class GenkitAdapterPlugin implements AdapterPlugin {
  const GenkitAdapterPlugin({this.provider = ModelProviders.googleGemma});

  /// Provider key whose LLM resolution gets wrapped.
  final String provider;

  @override
  void register(AdapterRegistry registry) {
    final innerFactory = registry.llmFactory(provider);
    if (innerFactory == null) {
      throw AdapterNotFoundError(provider: provider, capability: 'llm');
    }
    registry.registerLlm(
      provider,
      (context) => GenkitLlmAdapter(inner: innerFactory(context)),
    );
  }
}
