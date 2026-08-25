import 'package:local_ai_core/local_ai_core.dart';
import 'package:test/test.dart';

void main() {
  group('collapseRepeatedWords', () {
    test('collapses an immediately repeated single word', () {
      expect(collapseRepeatedWords('production production'), 'production');
    });

    test('collapses an immediately repeated multi-word phrase', () {
      expect(
        collapseRepeatedWords('the file is ready the file is ready'),
        'the file is ready',
      );
    });

    test('collapses triple-or-more repeats to a single occurrence', () {
      expect(
        collapseRepeatedWords('production production production'),
        'production',
      );
    });

    test('is case-insensitive when detecting repeats', () {
      expect(collapseRepeatedWords('Production production'), 'Production');
    });

    test('leaves clean text unchanged', () {
      expect(
        collapseRepeatedWords('the file is ready to ship'),
        'the file is ready to ship',
      );
    });

    test('collapses legitimate immediate doubles too (accepted tradeoff)', () {
      expect(collapseRepeatedWords('no no it is fine'), 'no it is fine');
    });

    test('returns empty or whitespace-only input unchanged', () {
      expect(collapseRepeatedWords(''), '');
      expect(collapseRepeatedWords('   '), '   ');
    });
  });
}
