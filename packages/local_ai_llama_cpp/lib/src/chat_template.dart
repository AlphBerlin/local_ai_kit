/// Pure chat templating for GGUF models.
///
/// llama.cpp's C API tokenizes plain text: turning `List<LlmMessage>` into
/// the turn markers a given model family was fine-tuned on is the caller's
/// job. GGUF files embed a chat template in their metadata, but
/// `llama_cpp_dart` does not expose `llama_model_chat_template`, so the
/// family is inferred from the model id / file name instead and rendered
/// here — pure, so every template is unit-testable (spec §2).
///
/// Templates never emit a beginning-of-sequence token: the worker tokenizes
/// with `add_special = true`, so llama.cpp prepends the model's own BOS.
library;

import 'package:local_ai_core/local_ai_core.dart';

/// Turn-marker dialects this adapter knows how to render.
enum LlamaChatFormat {
  /// `<|im_start|>role … <|im_end|>` — Qwen, Yi, SmolLM2, Hermes, DeepSeek
  /// R1 distills.
  chatml,

  /// `<start_of_turn>user … <end_of_turn>` — Gemma (no system role).
  gemma,

  /// `<|start_header_id|>role<|end_header_id|> … <|eot_id|>` — Llama 3.x.
  llama3,

  /// `[INST] … [/INST]` — Mistral / Mixtral (no system role).
  mistral,

  /// `<|system|> … <|end|>` — Phi-3 / Phi-4.
  phi,

  /// `System:` / `User:` / `Assistant:` — base models with no chat tuning.
  plain,
}

/// Renders chat histories into a prompt string for a [LlamaChatFormat].
abstract final class ChatTemplate {
  /// Guesses the turn-marker dialect from a model id or GGUF file name.
  ///
  /// Order matters: `llama-3` is checked before the generic `llama` that
  /// appears in many unrelated file names, and Gemma before everything else
  /// because `gemma` never uses ChatML.
  static LlamaChatFormat detect(String modelIdOrFileName) {
    final name = modelIdOrFileName.toLowerCase();
    bool has(String needle) => name.contains(needle);

    if (has('gemma')) return LlamaChatFormat.gemma;
    if (has('llama-3') ||
        has('llama3') ||
        has('llama_3') ||
        has('hermes-3') ||
        has('tulu-3')) {
      return LlamaChatFormat.llama3;
    }
    if (has('mistral') ||
        has('ministral') ||
        has('mixtral') ||
        has('zephyr')) {
      return LlamaChatFormat.mistral;
    }
    if (has('phi-3') || has('phi3') || has('phi-4') || has('phi4')) {
      return LlamaChatFormat.phi;
    }
    if (has('qwen') ||
        has('smollm') ||
        has('deepseek') ||
        has('yi-') ||
        has('hermes') ||
        has('olmo') ||
        has('lfm') ||
        has('instruct') ||
        has('-it-') ||
        has('chat')) {
      return LlamaChatFormat.chatml;
    }
    return LlamaChatFormat.plain;
  }

  /// Sequences that terminate an assistant turn in [format]. Passed to
  /// llama.cpp as stop strings on top of the model's own end-of-generation
  /// token.
  static List<String> stopSequences(LlamaChatFormat format) =>
      switch (format) {
        LlamaChatFormat.chatml => const ['<|im_end|>', '<|endoftext|>'],
        LlamaChatFormat.gemma => const ['<end_of_turn>'],
        LlamaChatFormat.llama3 => const ['<|eot_id|>', '<|end_of_text|>'],
        LlamaChatFormat.mistral => const ['</s>'],
        LlamaChatFormat.phi => const ['<|end|>'],
        LlamaChatFormat.plain => const ['\nUser:', '\nSystem:'],
      };

  /// Marker that closes an assistant turn.
  ///
  /// llama.cpp stops generating at the end-of-generation token *without*
  /// committing it to the KV cache, so a conversation continued from a live
  /// cache has to re-open with this marker before the next turn — otherwise
  /// the model sees its own answer running straight into the user's next
  /// message.
  static String assistantTurnSuffix(LlamaChatFormat format) =>
      switch (format) {
        LlamaChatFormat.chatml => '<|im_end|>\n',
        LlamaChatFormat.gemma => '<end_of_turn>\n',
        LlamaChatFormat.llama3 => '<|eot_id|>',
        LlamaChatFormat.mistral => '</s>',
        LlamaChatFormat.phi => '<|end|>\n',
        LlamaChatFormat.plain => '\n',
      };

  /// Renders only the new [messages] of a conversation whose earlier turns
  /// are already in a live KV cache, closing the assistant turn the cache
  /// currently ends on.
  static String renderContinuation(
    List<LlmMessage> messages, {
    required LlamaChatFormat format,
  }) {
    // A system message can't be injected mid-conversation without
    // rewriting the cached prefix; callers get here only when the prefix
    // matched, so any system message is already in the cache.
    final turns =
        messages.where((m) => m.role != LlmRole.system).toList(growable: false);
    return assistantTurnSuffix(format) +
        render(turns, format: format, addGenerationPrompt: true);
  }

  /// Renders [messages] for [format].
  ///
  /// When [addGenerationPrompt] is true the result ends with the opening
  /// marker of an assistant turn, which is what generation continues from.
  /// Formats without a system role (Gemma, Mistral) fold system messages
  /// into the first user turn rather than dropping them.
  static String render(
    List<LlmMessage> messages, {
    required LlamaChatFormat format,
    bool addGenerationPrompt = true,
  }) {
    final normalized = format == LlamaChatFormat.gemma ||
            format == LlamaChatFormat.mistral
        ? foldSystemIntoFirstUser(messages)
        : messages;

    final buffer = StringBuffer();
    for (final message in normalized) {
      buffer.write(_renderTurn(message, format));
    }
    if (addGenerationPrompt) buffer.write(_generationPrompt(format));
    return buffer.toString();
  }

  /// Merges every system message into the first user turn, for model
  /// families whose templates have no system role.
  static List<LlmMessage> foldSystemIntoFirstUser(List<LlmMessage> messages) {
    final system = messages
        .where((m) => m.role == LlmRole.system)
        .map((m) => m.content.trim())
        .where((c) => c.isNotEmpty)
        .join('\n\n');
    final rest =
        messages.where((m) => m.role != LlmRole.system).toList(growable: false);
    if (system.isEmpty) return rest;
    if (rest.isEmpty) return <LlmMessage>[LlmMessage.user(system)];

    final firstUserIndex = rest.indexWhere((m) => m.role == LlmRole.user);
    if (firstUserIndex < 0) {
      return <LlmMessage>[LlmMessage.user(system), ...rest];
    }
    final merged = <LlmMessage>[...rest];
    merged[firstUserIndex] = LlmMessage.user(
      '$system\n\n${merged[firstUserIndex].content}',
    );
    return merged;
  }

  static String _renderTurn(LlmMessage message, LlamaChatFormat format) {
    final content = message.content;
    switch (format) {
      case LlamaChatFormat.chatml:
        return '<|im_start|>${_roleName(message.role)}\n$content<|im_end|>\n';
      case LlamaChatFormat.gemma:
        final role = message.role == LlmRole.assistant ? 'model' : 'user';
        return '<start_of_turn>$role\n$content<end_of_turn>\n';
      case LlamaChatFormat.llama3:
        return '<|start_header_id|>${_roleName(message.role)}'
            '<|end_header_id|>\n\n$content<|eot_id|>';
      case LlamaChatFormat.mistral:
        return message.role == LlmRole.assistant
            ? '$content</s>'
            : '[INST] $content [/INST]';
      case LlamaChatFormat.phi:
        return '<|${_roleName(message.role)}|>\n$content<|end|>\n';
      case LlamaChatFormat.plain:
        return '${_plainRoleName(message.role)}: $content\n';
    }
  }

  static String _generationPrompt(LlamaChatFormat format) => switch (format) {
        LlamaChatFormat.chatml => '<|im_start|>assistant\n',
        LlamaChatFormat.gemma => '<start_of_turn>model\n',
        LlamaChatFormat.llama3 =>
          '<|start_header_id|>assistant<|end_header_id|>\n\n',
        // Mistral continues straight after [/INST]; nothing to open.
        LlamaChatFormat.mistral => '',
        LlamaChatFormat.phi => '<|assistant|>\n',
        LlamaChatFormat.plain => 'Assistant:',
      };

  static String _roleName(LlmRole role) => switch (role) {
        LlmRole.system => 'system',
        LlmRole.user => 'user',
        LlmRole.assistant => 'assistant',
      };

  static String _plainRoleName(LlmRole role) => switch (role) {
        LlmRole.system => 'System',
        LlmRole.user => 'User',
        LlmRole.assistant => 'Assistant',
      };
}
