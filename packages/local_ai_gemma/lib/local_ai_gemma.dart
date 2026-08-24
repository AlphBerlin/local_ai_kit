/// Gemma adapter for LocalAI Kit.
///
/// Maps `flutter_gemma` onto the core [LocalLlm] interface. All
/// flutter_gemma types stay inside this package (architecture §2 rule 2).
library;

export 'package:flutter_gemma/flutter_gemma.dart' show FlutterGemma;
export 'src/gemma_adapter_plugin.dart';
export 'src/gemma_llm_adapter.dart';
