/// Default structured-output implementation shared by adapters.
///
/// Strategy (architecture §7.8): schema injection + JSON extraction +
/// validation, retrying with an error-feedback prompt up to `maxRetries`
/// times before throwing [StructuredOutputError]. Runtimes with grammar /
/// constrained-decoding support should override [generateStructured] and
/// skip this prompt-based fallback.
library;

import 'dart:async';
import 'dart:convert';

import '../errors/local_ai_error.dart';
import 'json_schema.dart';
import 'llm_request.dart';
import 'local_llm.dart';

/// Mixin giving any [LocalLlm] a retrying, schema-validated
/// `generateStructured` on top of plain [LocalLlm.generate].
///
/// Declares [generate] as an abstract member instead of constraining with
/// `on LocalLlm`, so it can be mixed into fakes and adapters alike.
mixin StructuredOutputSupport {
  /// Provided by the host class ([LocalLlm.generate]).
  Future<LlmResponse> generate(LlmRequest request);

  /// Structured output with retry + validation; see [LocalLlm].
  Future<T> generateStructured<T>(
    String prompt, {
    required JsonSchema schema,
    required T Function(Map<String, dynamic> json) fromJson,
    int maxRetries = 2,
  }) async {
    String? lastRaw = '';
    String? lastError;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      final effectivePrompt = attempt == 0
          ? _structuredPrompt(prompt, schema)
          : _retryPrompt(prompt, schema, lastRaw ?? '', lastError!);

      final response = await generate(LlmRequest.prompt(
        effectivePrompt,
        responseSchema: schema,
      ));
      lastRaw = response.text;

      final json = extractJson(response.text);
      if (json is! Map<String, dynamic>) {
        lastError = 'Output did not contain a JSON object.';
        continue;
      }
      final validationError = schema.validate(json);
      if (validationError != null) {
        lastError = 'Schema validation failed: $validationError';
        continue;
      }
      try {
        return fromJson(json);
      } on Object catch (e) {
        lastError = 'fromJson threw: $e';
      }
    }

    throw StructuredOutputError(
      rawOutput: lastRaw ?? '',
      attempts: maxRetries + 1,
      reason: 'Structured output failed after ${maxRetries + 1} attempt(s). '
          'Last error: $lastError',
    );
  }

  String _structuredPrompt(String prompt, JsonSchema schema) {
    return '$prompt\n\n'
        'You MUST answer with a single JSON object and nothing else. '
        'The object MUST conform to this JSON Schema:\n'
        '${schema.toPromptString()}\n'
        'Do not wrap the JSON in markdown code fences.';
  }

  String _retryPrompt(
      String prompt, JsonSchema schema, String previousOutput, String error) {
    return 'Your previous answer was invalid.\n'
        'Error: $error\n'
        'Previous answer:\n$previousOutput\n\n'
        'Try again. Answer the original request with a single JSON object '
        'conforming to this JSON Schema, and nothing else:\n'
        '${schema.toPromptString()}\n\n'
        'Original request: $prompt';
  }

  /// Extracts the first JSON value found in [text], tolerating markdown
  /// fences and leading/trailing prose.
  static Object? extractJson(String text) {
    var candidate = text.trim();

    // Strip markdown code fences if present.
    final fenceMatch =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(candidate);
    if (fenceMatch != null) {
      candidate = fenceMatch.group(1)!.trim();
    } else {
      // Otherwise locate the first `{` ... last `}` span.
      final start = candidate.indexOf('{');
      final end = candidate.lastIndexOf('}');
      if (start >= 0 && end > start) {
        candidate = candidate.substring(start, end + 1);
      }
    }

    try {
      return jsonDecode(candidate);
    } on FormatException {
      return null;
    }
  }
}
