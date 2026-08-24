/// Genkit orchestrator: flows, tools and schema-validated actions on top of
/// a core [LocalLlm].
///
/// Positioning (architecture §7.1): Genkit on device is an orchestration
/// layer — flows / tools / prompt templates / structured output — not an
/// inference runtime. The underlying generation always goes through the
/// injected [LocalLlm].
///
/// The `genkit` package is used for flow tooling where it fits; the core
/// orchestration types below are self-contained so the adapter degrades
/// gracefully if the upstream Dart genkit API changes.
library;

import 'dart:async';
import 'package:local_ai_core/local_ai_core.dart';

import 'prompt_template.dart';

/// A tool the model-driven flow may invoke (function calling).
class GenkitTool<I, O> {
  const GenkitTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  final String name;
  final String description;

  /// JSON schema of the tool arguments, advertised to the model.
  final JsonSchema inputSchema;

  /// Executes the tool locally.
  final Future<O> Function(I input) handler;
}

/// A named, replayable orchestration unit.
class GenkitFlow<I, O> {
  const GenkitFlow({
    required this.name,
    required this.run,
    this.inputSchema,
    this.outputSchema,
  });

  final String name;
  final Future<O> Function(I input) run;
  final JsonSchema? inputSchema;
  final JsonSchema? outputSchema;
}

/// Registers and executes flows/tools; bridges to the inner LLM for
/// schema-validated structured output.
class GenkitOrchestrator {
  GenkitOrchestrator({required LocalLlm inner}) : _inner = inner;

  final LocalLlm _inner;
  final Map<String, GenkitFlow<Object?, Object?>> _flows = {};
  final Map<String, GenkitTool<Object?, Object?>> _tools = {};

  /// The wrapped LLM (escape hatch).
  LocalLlm get inner => _inner;

  /// Currently registered tools.
  List<GenkitTool<Object?, Object?>> get tools =>
      List.unmodifiable(_tools.values);

  /// Registers a flow. Re-registering the same name replaces it.
  void defineFlow<I, O>(GenkitFlow<I, O> flow) {
    _flows[flow.name] = GenkitFlow<Object?, Object?>(
      name: flow.name,
      inputSchema: flow.inputSchema,
      outputSchema: flow.outputSchema,
      run: (input) => flow.run(input as I),
    );
  }

  /// Registers a callable tool.
  void defineTool<I, O>(GenkitTool<I, O> tool) {
    _tools[tool.name] = GenkitTool<Object?, Object?>(
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
      handler: (input) => tool.handler(input as I),
    );
  }

  /// Runs a previously registered flow.
  ///
  /// Input is validated against the flow's `inputSchema` when present;
  /// output is validated against `outputSchema` when present. Validation
  /// failures throw [StructuredOutputError].
  Future<O> runFlow<I, O>(String name, I input) async {
    final flow = _flows[name];
    if (flow == null) {
      throw InvalidStateError('Genkit flow "$name" is not registered.');
    }
    final inputSchema = flow.inputSchema;
    if (inputSchema != null) {
      final error = inputSchema.validate(input);
      if (error != null) {
        throw StructuredOutputError(
          rawOutput: '$input',
          attempts: 1,
          reason: 'Flow "$name" input validation failed: $error',
        );
      }
    }
    final output = await flow.run(input);
    final outputSchema = flow.outputSchema;
    if (outputSchema != null) {
      final error = outputSchema.validate(output);
      if (error != null) {
        throw StructuredOutputError(
          rawOutput: '$output',
          attempts: 1,
          reason: 'Flow "$name" output validation failed: $error',
        );
      }
    }
    return output as O;
  }

  /// Structured generation with retry, delegating to the inner LLM's
  /// [LocalLlm.generateStructured].
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  }) {
    return _inner.generateStructured(
      prompt,
      schema: schema,
      fromJson: fromJson,
      maxRetries: maxRetries,
    );
  }

  /// Renders a [template] and generates from it in one call.
  Future<LlmResponse> generateFromTemplate(
    PromptTemplate template,
    Map<String, Object?> variables,
  ) {
    return _inner.generate(LlmRequest.prompt(template.render(variables)));
  }
}