import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_kit/local_ai_kit.dart';

void main() {
  group('extractSentences', () {
    test('extracts a single complete sentence and keeps the remainder', () {
      final result = extractSentences('Hello world. How are');
      expect(result.sentences, ['Hello world.']);
      expect(result.remainder, ' How are');
    });

    test('extracts multiple complete sentences from one buffer', () {
      final result = extractSentences('One. Two! Three? ');
      expect(result.sentences, ['One.', 'Two!', 'Three?']);
      expect(result.remainder, '');
    });

    test('returns no sentences when there is no boundary yet', () {
      final result = extractSentences('Hello there');
      expect(result.sentences, isEmpty);
      expect(result.remainder, 'Hello there');
    });

    test('preserves trailing whitespace in an incomplete remainder', () {
      final result = extractSentences('Hello ');
      expect(result.sentences, isEmpty);
      expect(result.remainder, 'Hello ');
    });

    test('extracts a sentence ending at the end of the buffer', () {
      final result = extractSentences('Hello.');
      expect(result.sentences, ['Hello.']);
      expect(result.remainder, '');
    });

    test('does not split on a decimal point', () {
      final result = extractSentences('3.14 is pi. ');
      expect(result.sentences, ['3.14 is pi.']);
      expect(result.remainder, '');
    });

    test('returns no sentences for an empty buffer', () {
      final result = extractSentences('');
      expect(result.sentences, isEmpty);
      expect(result.remainder, '');
    });
  });
}
