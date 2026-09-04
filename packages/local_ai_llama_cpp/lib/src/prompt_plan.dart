/// Pure decision layer for reusing a persistent llama.cpp KV cache
/// across turns (spec §2, "persistent `llama_context`").
///
/// Keeping the context alive between requests is the main performance lever
/// of this adapter, but it is only correct while the new request extends the
/// history already in the cache. This file decides — with no I/O and no
/// native calls — whether the next request can continue the existing cache
/// or has to start from a cleared one.
library;

import 'package:local_ai_core/local_ai_core.dart';

/// What the worker should feed llama.cpp for the next request.
class PromptPlan {
  const PromptPlan._({
    required this.messages,
    required this.reusesCache,
  });

  /// Continue the live context: only [messages] (the new tail) get
  /// tokenized; everything before them is already in the KV cache.
  const PromptPlan.reuse(List<LlmMessage> messages)
      : this._(messages: messages, reusesCache: true);

  /// Clear the context and re-feed the whole conversation.
  const PromptPlan.reset(List<LlmMessage> messages)
      : this._(messages: messages, reusesCache: false);

  /// Messages to tokenize for this request.
  final List<LlmMessage> messages;

  /// True when the existing KV cache is kept.
  final bool reusesCache;

  @override
  String toString() =>
      'PromptPlan(${reusesCache ? 'reuse' : 'reset'}, ${messages.length} msg)';
}

/// Decides between continuing and resetting the cached context.
abstract final class PromptPlanner {
  /// Plans the next request.
  ///
  /// [cached] is the exact message sequence already evaluated into the live
  /// context (including the assistant turns the model itself produced, which
  /// are in the KV cache whether or not the caller echoes them back).
  /// [next] is the (already truncated) request history.
  ///
  /// The cache is reused only when [next] starts with [cached] verbatim and
  /// actually adds something. Any edit to earlier turns — a changed system
  /// prompt, a regenerated answer, a dropped turn after truncation —
  /// invalidates the prefix and forces a reset, because llama.cpp cannot
  /// rewrite tokens already committed to the cache.
  static PromptPlan plan({
    required List<LlmMessage> cached,
    required List<LlmMessage> next,
  }) {
    if (cached.isEmpty) return PromptPlan.reset(next);
    if (next.length <= cached.length) return PromptPlan.reset(next);
    for (var i = 0; i < cached.length; i++) {
      if (!_sameMessage(cached[i], next[i])) return PromptPlan.reset(next);
    }
    return PromptPlan.reuse(next.sublist(cached.length));
  }

  static bool _sameMessage(LlmMessage a, LlmMessage b) =>
      a.role == b.role && a.content == b.content;
}
