/// Pure sliding-window truncation for chat histories (spec §2).
///
/// Extracted from the adapter so the policy is unit-testable without a
/// loaded model. Mirrors `GemmaLlmAdapter`'s behaviour: keep every system
/// message plus as many of the most recent turns as fit, and report whether
/// anything was dropped so the adapter can flag `LlmChunk.contextTruncated`.
library;

import 'package:local_ai_core/local_ai_core.dart';

/// Result of applying the context window to a request.
class ContextWindowResult {
  const ContextWindowResult({required this.messages, required this.truncated});

  /// The messages that survived truncation, in their original order.
  final List<LlmMessage> messages;

  /// True when at least one turn was dropped to fit the window.
  final bool truncated;
}

/// Sliding-window truncation over a chat history.
abstract final class ContextWindow {
  /// Rough characters-per-token estimate used when no tokenizer is
  /// available. llama.cpp tokenizes for real inside the worker isolate; this
  /// estimate only decides which turns to send.
  static const int charsPerToken = 4;

  /// Fraction of the context window reserved for the model's own answer.
  static const double generationHeadroom = 0.25;

  /// Keeps the system prompt plus the newest turns that fit in
  /// [maxContextTokens].
  ///
  /// `null` [maxContextTokens] means "model default" — nothing is dropped.
  /// The newest turn is always kept even when it alone overflows the
  /// budget; llama.cpp then reports the real context error rather than the
  /// adapter silently sending an empty prompt.
  static ContextWindowResult apply(
    List<LlmMessage> messages, {
    int? maxContextTokens,
    int? maxOutputTokens,
  }) {
    if (maxContextTokens == null || maxContextTokens <= 0) {
      return ContextWindowResult(messages: messages, truncated: false);
    }

    final reserved = maxOutputTokens ??
        (maxContextTokens * generationHeadroom).round().clamp(0, maxContextTokens);
    final budgetChars = ((maxContextTokens - reserved) * charsPerToken)
        .clamp(0, maxContextTokens * charsPerToken);

    final system = <LlmMessage>[];
    final turns = <LlmMessage>[];
    for (final message in messages) {
      (message.role == LlmRole.system ? system : turns).add(message);
    }

    var used = system.fold<int>(0, (sum, m) => sum + m.content.length);
    final kept = <LlmMessage>[];
    for (final message in turns.reversed) {
      if (kept.isNotEmpty && used + message.content.length > budgetChars) break;
      used += message.content.length;
      kept.insert(0, message);
    }

    if (kept.length == turns.length) {
      return ContextWindowResult(messages: messages, truncated: false);
    }
    return ContextWindowResult(
      messages: <LlmMessage>[...system, ...kept],
      truncated: true,
    );
  }

  /// Estimated prompt tokens for [messages] (same 4-chars-per-token rule).
  static int estimateTokens(List<LlmMessage> messages) {
    final chars = messages.fold<int>(0, (sum, m) => sum + m.content.length);
    return (chars / charsPerToken).ceil();
  }
}
