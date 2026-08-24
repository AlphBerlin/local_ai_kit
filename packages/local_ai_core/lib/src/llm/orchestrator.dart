/// Escape-hatch interface for orchestration layers (architecture §3.5).
library;

/// Implemented by LLM adapters that wrap another adapter with an
/// orchestration layer (e.g. `GenkitLlmAdapter`).
///
/// Core deliberately types the orchestrator as [Object]: the concrete type
/// (`GenkitOrchestrator`) lives in the genkit package, which depends on
/// core — never the reverse.
abstract interface class OrchestratorProvider {
  /// The orchestration facade over this adapter, or `null` when the
  /// adapter has no orchestration layer.
  Object? get orchestrator;
}
