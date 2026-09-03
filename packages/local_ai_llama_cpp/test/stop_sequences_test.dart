import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

void main() {
  test('passes text through when there is nothing to stop on', () {
    final scanner = StopSequenceScanner(const []);
    expect(scanner.add('hello').text, 'hello');
    expect(scanner.stopped, isFalse);
  });

  test('cuts the output at a stop sequence', () {
    final scanner = StopSequenceScanner(const ['<|im_end|>']);
    final result = scanner.add('Hi there<|im_end|>trailing');
    expect(result.text, 'Hi there');
    expect(result.stopped, isTrue);
    expect(scanner.add('more').text, isEmpty);
  });

  test('holds back a partial marker instead of leaking it', () {
    final scanner = StopSequenceScanner(const ['<|im_end|>']);
    expect(scanner.add('Hi <|im_').text, 'Hi ');
    expect(scanner.add('end|>').text, isEmpty);
    expect(scanner.stopped, isTrue);
  });

  test('a partial marker that turns out to be text is flushed', () {
    final scanner = StopSequenceScanner(const ['<|im_end|>']);
    expect(scanner.add('Hi <|im_').text, 'Hi ');
    expect(scanner.add('possible').text, '<|im_possible');
    expect(scanner.stopped, isFalse);
  });

  test('flush returns whatever was held back at end of generation', () {
    final scanner = StopSequenceScanner(const ['<|im_end|>']);
    scanner.add('done<|im');
    expect(scanner.flush(), '<|im');
    expect(scanner.flush(), isEmpty);
  });

  test('flush is empty once a stop sequence matched', () {
    final scanner = StopSequenceScanner(const ['</s>']);
    scanner.add('bye</s>');
    expect(scanner.flush(), isEmpty);
  });

  test('the earliest of several stop sequences wins', () {
    final scanner = StopSequenceScanner(const ['<|end|>', 'STOP']);
    expect(scanner.add('a STOP b <|end|>').text, 'a ');
    expect(scanner.stopped, isTrue);
  });

  test('a stop sequence split across many deltas is still caught', () {
    final scanner = StopSequenceScanner(const ['<end_of_turn>']);
    final emitted = StringBuffer();
    for (final delta in ['ok', '<end', '_of', '_turn', '>']) {
      emitted.write(scanner.add(delta).text);
    }
    expect(emitted.toString(), 'ok');
    expect(scanner.stopped, isTrue);
  });
}
