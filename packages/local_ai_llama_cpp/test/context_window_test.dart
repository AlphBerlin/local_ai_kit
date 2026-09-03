import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

LlmMessage user(String text) => LlmMessage.user(text);
LlmMessage assistant(String text) => LlmMessage.assistant(text);

void main() {
  test('no cap means no truncation', () {
    final messages = [user('a' * 10000), assistant('b' * 10000)];
    final result = ContextWindow.apply(messages);
    expect(result.truncated, isFalse);
    expect(result.messages, same(messages));
  });

  test('a history that fits is returned untouched', () {
    final messages = [const LlmMessage.system('sys'), user('hi')];
    final result = ContextWindow.apply(messages, maxContextTokens: 4096);
    expect(result.truncated, isFalse);
    expect(result.messages, same(messages));
  });

  test('oldest turns are dropped first and the system prompt is kept', () {
    final messages = [
      const LlmMessage.system('S'),
      user('a' * 400),
      assistant('b' * 400),
      user('c' * 400),
    ];
    // 300 tokens ≈ 1200 chars, minus 25% headroom ≈ 900 chars of history.
    final result = ContextWindow.apply(messages, maxContextTokens: 300);
    expect(result.truncated, isTrue);
    expect(result.messages.first.role, LlmRole.system);
    expect(result.messages.length, 3);
    expect(result.messages.last.content, 'c' * 400);
  });

  test('the newest turn survives even when it alone overflows', () {
    final messages = [user('a' * 100), user('b' * 100000)];
    final result = ContextWindow.apply(messages, maxContextTokens: 128);
    expect(result.truncated, isTrue);
    expect(result.messages.single.content, 'b' * 100000);
  });

  test('an explicit output budget shrinks the history budget', () {
    final messages = [user('a' * 400), user('b' * 400)];
    final roomy = ContextWindow.apply(messages, maxContextTokens: 400);
    final tight =
        ContextWindow.apply(messages, maxContextTokens: 400, maxOutputTokens: 380);
    expect(roomy.truncated, isFalse);
    expect(tight.truncated, isTrue);
  });

  test('token estimate follows the 4-chars-per-token rule', () {
    expect(ContextWindow.estimateTokens([user('12345678')]), 2);
    expect(ContextWindow.estimateTokens([user('123')]), 1);
    expect(ContextWindow.estimateTokens(const []), 0);
  });
}
