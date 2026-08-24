/// Strongly typed `ai.genkit` escape hatch (architecture §3.5).
///
/// Only available when the app depends on `local_ai_genkit` — exactly the
/// point of the extension: core and kit stay free of genkit types.
library;

import 'package:local_ai_kit/local_ai_kit.dart';

import 'genkit_orchestrator.dart';

extension LocalAIGenkitX on LocalAI {
  /// The Genkit orchestrator wrapping the configured LLM, or `null` when
  /// Genkit is not enabled (register `GenkitAdapterPlugin` after the base
  /// LLM plugin and set `LlmConfig.enableGenkit`).
  GenkitOrchestrator? get genkit =>
      genkitOrchestrator as GenkitOrchestrator?;
}
