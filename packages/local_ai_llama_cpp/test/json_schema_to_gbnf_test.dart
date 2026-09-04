import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:local_ai_llama_cpp/local_ai_llama_cpp.dart';

/// Returns the right-hand side of `name ::= …` in [grammar].
String rule(String grammar, String name) {
  final line = grammar
      .split('\n')
      .firstWhere((l) => l.startsWith('$name ::= '), orElse: () => '');
  return line.isEmpty ? '' : line.substring('$name ::= '.length);
}

void main() {
  group('primitives', () {
    test('every grammar defines the shared JSON primitives', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.string());
      for (final name in const [
        'value',
        'object',
        'array',
        'string',
        'char',
        'hex',
        'integer',
        'number',
        'boolean',
        'null',
        'space',
      ]) {
        expect(rule(grammar, name), isNotEmpty, reason: 'missing rule $name');
      }
    });

    test('space is bounded so a constrained model cannot stall', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.string());
      expect(rule(grammar, 'space'), '" "?');
    });

    test('scalar schemas map onto the primitive rules', () {
      expect(rule(JsonSchemaToGbnf.convert(JsonSchema.string()), 'root'),
          'string');
      expect(rule(JsonSchemaToGbnf.convert(JsonSchema.number()), 'root'),
          'number');
      expect(rule(JsonSchemaToGbnf.convert(JsonSchema.integer()), 'root'),
          'integer');
      expect(rule(JsonSchemaToGbnf.convert(JsonSchema.boolean()), 'root'),
          'boolean');
    });

    test('a schema with no recognised type falls back to any JSON value', () {
      final grammar =
          JsonSchemaToGbnf.convertMap(const <String, Object?>{'title': 'x'});
      expect(rule(grammar, 'root'), 'value');
    });
  });

  group('objects', () {
    test('required properties are mandatory and comma-separated', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object(
        properties: {
          'fact': JsonSchema.string(),
          'score': JsonSchema.number(),
        },
        required: ['fact', 'score'],
      ));
      expect(
        rule(grammar, 'root'),
        '"{" space root-fact-kv "," space root-score-kv "}" space',
      );
      expect(rule(grammar, 'root-fact-kv'), '"\\"fact\\"" space ":" space string');
      expect(
          rule(grammar, 'root-score-kv'), '"\\"score\\"" space ":" space number');
    });

    test('optional properties after a required one are skippable', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object(
        properties: {
          'id': JsonSchema.integer(),
          'note': JsonSchema.string(),
        },
        required: ['id'],
      ));
      expect(
        rule(grammar, 'root'),
        '"{" space root-id-kv ( "," space root-note-kv )? "}" space',
      );
    });

    test('an all-optional object enumerates which key may come first', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object(
        properties: {
          'a': JsonSchema.string(),
          'b': JsonSchema.string(),
        },
      ));
      expect(
        rule(grammar, 'root'),
        '"{" space ( root-a-kv ( "," space root-b-kv )? | root-b-kv )? "}" space',
      );
    });

    test('an object with no properties admits only {}', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object());
      expect(rule(grammar, 'root'), '"{" space "}" space');
    });

    test('nested objects get their own kv rules', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object(
        properties: {
          'user': JsonSchema.object(
            properties: {'name': JsonSchema.string()},
            required: ['name'],
          ),
        },
        required: ['user'],
      ));
      expect(rule(grammar, 'root-user-name-kv'),
          '"\\"name\\"" space ":" space string');
      expect(
        rule(grammar, 'root-user-kv'),
        '"\\"user\\"" space ":" space "{" space root-user-name-kv "}" space',
      );
    });
  });

  group('arrays and enums', () {
    test('arrays allow zero or more items', () {
      final grammar = JsonSchemaToGbnf.convert(
          JsonSchema.array(items: JsonSchema.string()));
      expect(rule(grammar, 'root'),
          '"[" space ( root-item ( "," space root-item )* )? "]" space');
      expect(rule(grammar, 'root-item'), 'string');
    });

    test('enums become a literal alternation', () {
      final grammar = JsonSchemaToGbnf.convert(
          JsonSchema.string(enumValues: ['yes', 'no']));
      expect(rule(grammar, 'root'), '("\\"yes\\"" | "\\"no\\"") space');
    });

    test('literals with quotes and backslashes are escaped', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object(
        properties: {r'a"b\c': JsonSchema.string()},
        required: [r'a"b\c'],
      ));
      expect(grammar, contains(r'"\"a\"b\\c\""'));
    });

    test('keys that are not valid rule names are sanitised', () {
      final grammar = JsonSchemaToGbnf.convert(JsonSchema.object(
        properties: {'first name': JsonSchema.string()},
        required: ['first name'],
      ));
      expect(rule(grammar, 'root-first-name-kv'), isNotEmpty);
    });
  });
}
