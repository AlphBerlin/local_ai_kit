/// Optional Genkit orchestration layer (architecture §3.5, §7.1).
///
/// Wraps any core [LocalLlm] with flows / tools / prompt templates and
/// schema-validated structured output. Core stays free of genkit types.
library;

export 'package:genkit/genkit.dart';

export 'src/genkit_adapter_plugin.dart';
export 'src/genkit_llm_adapter.dart';
export 'src/genkit_orchestrator.dart';
export 'src/genkit_skills_x.dart';
export 'src/local_ai_genkit_x.dart';
export 'src/prompt_template.dart';
