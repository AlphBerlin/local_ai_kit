import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

void main() {
  group('format detection', () {
    test('recognises the families the catalog ships', () {
      expect(ChatTemplate.detect('qwen2.5-0.5b-instruct-q4_k_m.gguf'),
          LlamaChatFormat.chatml);
      expect(ChatTemplate.detect('gemma-2-2b-it-Q4_K_M.gguf'),
          LlamaChatFormat.gemma);
      expect(ChatTemplate.detect('Meta-Llama-3.1-8B-Instruct.gguf'),
          LlamaChatFormat.llama3);
      expect(ChatTemplate.detect('mistral-7b-instruct-v0.3.gguf'),
          LlamaChatFormat.mistral);
      expect(ChatTemplate.detect('Ministral-3-3B-Instruct-2512-Q4_K_M.gguf'),
          LlamaChatFormat.mistral);
      expect(ChatTemplate.detect('Phi-3-mini-4k-instruct-q4.gguf'),
          LlamaChatFormat.phi);
      expect(ChatTemplate.detect('SmolLM2-360M-Instruct-Q8_0.gguf'),
          LlamaChatFormat.chatml);
      expect(ChatTemplate.detect('LFM2.5-1.2B-JP-Q4_K_M.gguf'),
          LlamaChatFormat.chatml);
      expect(ChatTemplate.detect('LFM2.5-2.6B-Q4_K_M.gguf'),
          LlamaChatFormat.chatml);
      expect(ChatTemplate.detect('LFM2.5-8B-A1B-Q4_K_M.gguf'),
          LlamaChatFormat.chatml);
    });

    test('gemma wins over the generic instruct/chat hints', () {
      expect(ChatTemplate.detect('gemma-3-4b-it-chat.gguf'),
          LlamaChatFormat.gemma);
    });

    test('a base model with no chat hints falls back to plain', () {
      expect(ChatTemplate.detect('tinystories-33m-f16.gguf'),
          LlamaChatFormat.plain);
    });
  });

  group('rendering', () {
    const messages = [
      LlmMessage.system('Be brief.'),
      LlmMessage.user('Hi'),
      LlmMessage.assistant('Hello.'),
      LlmMessage.user('Bye'),
    ];

    test('chatml renders every role and opens the assistant turn', () {
      expect(
        ChatTemplate.render(messages, format: LlamaChatFormat.chatml),
        '<|im_start|>system\nBe brief.<|im_end|>\n'
        '<|im_start|>user\nHi<|im_end|>\n'
        '<|im_start|>assistant\nHello.<|im_end|>\n'
        '<|im_start|>user\nBye<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });

    test('gemma folds the system prompt into the first user turn', () {
      expect(
        ChatTemplate.render(messages, format: LlamaChatFormat.gemma),
        '<start_of_turn>user\nBe brief.\n\nHi<end_of_turn>\n'
        '<start_of_turn>model\nHello.<end_of_turn>\n'
        '<start_of_turn>user\nBye<end_of_turn>\n'
        '<start_of_turn>model\n',
      );
    });

    test('llama3 uses header ids and eot markers', () {
      expect(
        ChatTemplate.render(
          const [LlmMessage.user('Hi')],
          format: LlamaChatFormat.llama3,
        ),
        '<|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\n',
      );
    });

    test('mistral has no separate generation prompt after [/INST]', () {
      expect(
        ChatTemplate.render(
          const [LlmMessage.user('Hi')],
          format: LlamaChatFormat.mistral,
        ),
        '[INST] Hi [/INST]',
      );
    });

    test('no template emits a BOS token (the tokenizer adds it)', () {
      for (final format in LlamaChatFormat.values) {
        final rendered =
            ChatTemplate.render(messages, format: format);
        expect(rendered, isNot(contains('<|begin_of_text|>')));
        expect(rendered, isNot(startsWith('<s>')));
      }
    });

    test('addGenerationPrompt: false stops after the last turn', () {
      expect(
        ChatTemplate.render(
          const [LlmMessage.user('Hi')],
          format: LlamaChatFormat.chatml,
          addGenerationPrompt: false,
        ),
        '<|im_start|>user\nHi<|im_end|>\n',
      );
    });
  });

  group('continuation', () {
    test('closes the cached assistant turn before the new one', () {
      expect(
        ChatTemplate.renderContinuation(
          const [LlmMessage.user('Bye')],
          format: LlamaChatFormat.chatml,
        ),
        '<|im_end|>\n<|im_start|>user\nBye<|im_end|>\n<|im_start|>assistant\n',
      );
    });

    test('drops system messages, which are already in the cached prefix', () {
      final rendered = ChatTemplate.renderContinuation(
        const [LlmMessage.system('ignored'), LlmMessage.user('Bye')],
        format: LlamaChatFormat.chatml,
      );
      expect(rendered, isNot(contains('ignored')));
    });
  });

  group('stop sequences', () {
    test('every format declares the marker that ends its assistant turn', () {
      for (final format in LlamaChatFormat.values) {
        expect(ChatTemplate.stopSequences(format), isNotEmpty);
      }
      expect(ChatTemplate.stopSequences(LlamaChatFormat.chatml),
          contains('<|im_end|>'));
      expect(ChatTemplate.stopSequences(LlamaChatFormat.gemma),
          contains('<end_of_turn>'));
    });
  });

  group('foldSystemIntoFirstUser', () {
    test('a system-only history becomes a user turn', () {
      final folded = ChatTemplate.foldSystemIntoFirstUser(
          const [LlmMessage.system('Only rules.')]);
      expect(folded.single.role, LlmRole.user);
      expect(folded.single.content, 'Only rules.');
    });

    test('a history with no system message is unchanged', () {
      const input = [LlmMessage.user('Hi')];
      expect(ChatTemplate.foldSystemIntoFirstUser(input), input);
    });

    test('multiple system messages are joined', () {
      final folded = ChatTemplate.foldSystemIntoFirstUser(const [
        LlmMessage.system('One.'),
        LlmMessage.system('Two.'),
        LlmMessage.user('Hi'),
      ]);
      expect(folded.single.content, 'One.\n\nTwo.\n\nHi');
    });
  });
}
