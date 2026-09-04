/// Registration plugin + the `ai.genkit` escape hatch (architecture §3.5).
library;

import 'package:local_ai_core/local_ai_core.dart';

import 'genkit_llm_adapter.dart';

/// Wraps whichever LLM adapter resolves for a manifest with the Genkit
/// orchestration layer.
///
/// Registration order matters: register the base adapter plugins (e.g.
/// `GemmaAdapterPlugin`, `LlamaCppAdapterPlugin`) first, then this plugin
/// to take over LLM resolution with the decorated adapter.
///
/// If neither [provider] nor [providers] is specified, all registered LLM
/// providers in the registry (e.g. `google-gemma` and `llama-cpp`) are wrapped
/// automatically:
/// ```dart
/// await LocalAI.initialize(
///   config,
///   plugins: [
///     GemmaAdapterPlugin(),
///     LlamaCppAdapterPlugin(),
///     GenkitAdapterPlugin(),
///   ],
/// );
/// ```
class GenkitAdapterPlugin implements AdapterPlugin {
  const GenkitAdapterPlugin({
    this.provider,
    this.providers,
  });

  /// Single provider key whose LLM resolution gets wrapped.
  final String? provider;

  /// Multiple provider keys whose LLM resolution gets wrapped.
  final List<String>? providers;

  @override
  void register(AdapterRegistry registry) {
    final targetProviders = providers ??
        (provider != null
            ? [provider!]
            : (registry.registeredLlmProviders.isNotEmpty
                ? registry.registeredLlmProviders.toList()
                : const [ModelProviders.googleGemma]));

    for (final p in targetProviders) {
      final innerFactory = registry.llmFactory(p);
      if (innerFactory == null) {
        throw AdapterNotFoundError(provider: p, capability: 'llm');
      }
      registry.registerLlm(
        p,
        (context) => GenkitLlmAdapter(inner: innerFactory(context)),
      );
    }
  }
}
