import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

void main() {
  const system = LlmMessage.system('You are helpful.');
  const turn1 = LlmMessage.user('Hello');
  const answer1 = LlmMessage.assistant('Hi!');
  const turn2 = LlmMessage.user('And now?');

  test('an empty cache always resets', () {
    final plan = PromptPlanner.plan(cached: const [], next: const [turn1]);
    expect(plan.reusesCache, isFalse);
    expect(plan.messages, const [turn1]);
  });

  test('a strict extension of the cache reuses it and sends only the tail', () {
    final plan = PromptPlanner.plan(
      cached: const [system, turn1, answer1],
      next: const [system, turn1, answer1, turn2],
    );
    expect(plan.reusesCache, isTrue);
    expect(plan.messages, const [turn2]);
  });

  test('an edited earlier turn resets', () {
    final plan = PromptPlanner.plan(
      cached: const [system, turn1, answer1],
      next: const [
        system,
        LlmMessage.user('Hello there'),
        answer1,
        turn2,
      ],
    );
    expect(plan.reusesCache, isFalse);
    expect(plan.messages.length, 4);
  });

  test('a changed system prompt resets', () {
    final plan = PromptPlanner.plan(
      cached: const [system, turn1, answer1],
      next: const [LlmMessage.system('New rules.'), turn1, answer1, turn2],
    );
    expect(plan.reusesCache, isFalse);
  });

  test('a history that does not echo the assistant turn resets', () {
    // The single-shot `LlmRequest.prompt` shape: no assistant turn echoed.
    final plan = PromptPlanner.plan(
      cached: const [system, turn1, answer1],
      next: const [system, turn2],
    );
    expect(plan.reusesCache, isFalse);
  });

  test('an identical (not longer) history resets rather than sending nothing',
      () {
    final plan = PromptPlanner.plan(
      cached: const [system, turn1],
      next: const [system, turn1],
    );
    expect(plan.reusesCache, isFalse);
  });
}
