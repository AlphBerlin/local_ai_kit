/// LLM request / response data models.
library;

import 'dart:async';
import 'json_schema.dart';

/// Chat roles understood by every adapter.
enum LlmRole { system, user, assistant }

/// One message in a chat conversation.
class LlmMessage {
  const LlmMessage({required this.role, required this.content});

  final LlmRole role;
  final String content;

  const LlmMessage.system(String content)
      : this(role: LlmRole.system, content: content);
  const LlmMessage.user(String content)
      : this(role: LlmRole.user, content: content);
  const LlmMessage.assistant(String content)
      : this(role: LlmRole.assistant, content: content);

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role.name,
        'content': content,
      };

  factory LlmMessage.fromJson(Map<String, Object?> json) => LlmMessage(
        role: LlmRole.values.byName(json['role'] as String),
        content: json['content'] as String,
      );

  @override
  String toString() => 'LlmMessage(${role.name}, ${content.length} chars)';
}

/// A generation request.
class LlmRequest {
  const LlmRequest({
    required this.messages,
    this.temperature,
    this.maxTokens,
    this.topP,
    this.stopSequences = const [],
    this.responseSchema,
  });

  /// Convenience constructor for a single-turn user prompt.
  factory LlmRequest.prompt(
    String prompt, {
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    JsonSchema? responseSchema,
  }) {
    return LlmRequest(
      messages: <LlmMessage>[
        if (systemPrompt != null) LlmMessage.system(systemPrompt),
        LlmMessage.user(prompt),
      ],
      temperature: temperature,
      maxTokens: maxTokens,
      responseSchema: responseSchema,
    );
  }

  final List<LlmMessage> messages;

  /// Sampling temperature; `null` = adapter/model default.
  final double? temperature;

  /// Maximum number of tokens to generate; `null` = model default.
  final int? maxTokens;

  /// Nucleus sampling parameter; `null` = model default.
  final double? topP;

  /// Stop generation when any of these sequences is produced.
  final List<String> stopSequences;

  /// When set, the model is constrained (by grammar when the runtime
  /// supports it, otherwise by prompt injection) to answer with JSON
  /// matching this schema.
  final JsonSchema? responseSchema;

  LlmRequest copyWith({
    List<LlmMessage>? messages,
    double? temperature,
    int? maxTokens,
    double? topP,
    List<String>? stopSequences,
    JsonSchema? responseSchema,
  }) {
    return LlmRequest(
      messages: messages ?? this.messages,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      topP: topP ?? this.topP,
      stopSequences: stopSequences ?? this.stopSequences,
      responseSchema: responseSchema ?? this.responseSchema,
    );
  }
}

/// Why generation stopped.
enum LlmFinishReason { stop, length, cancelled, error, contentFiltered }

/// One streamed piece of a generation.
class LlmChunk {
  const LlmChunk({
    this.textDelta = '',
    this.isFinal = false,
    this.finishReason,
    this.contextTruncated = false,
    this.promptTokens,
    this.completionTokens,
  });

  /// Incremental text produced since the previous chunk.
  final String textDelta;

  /// True for the terminal chunk.
  final bool isFinal;

  /// Set on the final chunk.
  final LlmFinishReason? finishReason;

  /// True when the adapter had to truncate older conversation turns to fit
  /// the context window (see architecture §7.3).
  final bool contextTruncated;

  /// Token accounting when the runtime reports it (usually on final chunk).
  final int? promptTokens;
  final int? completionTokens;
}

/// Folded, non-streaming generation result.
class LlmResponse {
  const LlmResponse({
    required this.text,
    required this.finishReason,
    this.contextTruncated = false,
    this.promptTokens,
    this.completionTokens,
  });

  final String text;
  final LlmFinishReason finishReason;
  final bool contextTruncated;
  final int? promptTokens;
  final int? completionTokens;

  /// Folds a chunk stream into a single response.
  static Future<LlmResponse> fold(Stream<LlmChunk> chunks) async {
    final buffer = StringBuffer();
    var finishReason = LlmFinishReason.stop;
    var contextTruncated = false;
    int? promptTokens;
    int? completionTokens;
    await for (final chunk in chunks) {
      buffer.write(chunk.textDelta);
      contextTruncated = contextTruncated || chunk.contextTruncated;
      promptTokens = chunk.promptTokens ?? promptTokens;
      completionTokens = chunk.completionTokens ?? completionTokens;
      if (chunk.isFinal) {
        finishReason = chunk.finishReason ?? LlmFinishReason.stop;
      }
    }
    return LlmResponse(
      text: buffer.toString(),
      finishReason: finishReason,
      contextTruncated: contextTruncated,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }
}
