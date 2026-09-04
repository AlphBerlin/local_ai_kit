/// Pure translator: core [JsonSchema] → GBNF grammar for llama.cpp.
///
/// llama.cpp can constrain sampling with a GBNF grammar, which makes invalid
/// JSON unreachable instead of merely unlikely. This file is deliberately
/// dependency-free and side-effect-free so the whole translation is
/// exhaustively unit-testable without a loaded model (spec §3).
library;

import 'package:local_ai_core/local_ai_core.dart';

/// Translates the [JsonSchema] subset the kit supports into GBNF.
///
/// Supported: `object` (with `properties` / `required`), `array` (with
/// `items`), `string` (with `enum`), `number`, `integer`, `boolean`. Any
/// schema without a recognised `type` falls back to a permissive
/// "any JSON value" rule.
///
/// Two deliberate simplifications, both documented in `docs/adapters.md`:
///  * objects are closed — the grammar never permits a key that is not in
///    `properties`, regardless of `additionalProperties`;
///  * keys are emitted in declaration order (required first, then optional),
///    which is a subset of what JSON allows but is what llama.cpp's own
///    `json-schema-to-grammar` converter does too.
abstract final class JsonSchemaToGbnf {
  /// Name of the entry rule llama.cpp starts from.
  static const String rootRule = 'root';

  /// Converts [schema] into a complete GBNF grammar string whose entry point
  /// is [rootRule].
  static String convert(JsonSchema schema) => convertMap(schema.toMap());

  /// Same as [convert] for an already-unwrapped schema map.
  static String convertMap(Map<String, Object?> schema) {
    final builder = _GrammarBuilder();
    final rootBody = builder.bodyFor(schema, rootRule);
    return builder.render(rootBody);
  }
}

/// Accumulates named rules and renders them in insertion order.
class _GrammarBuilder {
  final Map<String, String> _rules = <String, String>{};
  /// Reserved: the entry rule plus every primitive emitted by [_primitives].
  final Set<String> _usedNames = <String>{
    JsonSchemaToGbnf.rootRule,
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
  };

  /// Emits the grammar text: `root` first, then every helper rule.
  String render(String rootBody) {
    final buffer = StringBuffer()
      ..writeln('${JsonSchemaToGbnf.rootRule} ::= $rootBody');
    for (final entry in _rules.entries) {
      buffer.writeln('${entry.key} ::= ${entry.value}');
    }
    buffer.write(_primitives());
    return buffer.toString();
  }

  /// Returns the right-hand side of the rule describing [schema].
  ///
  /// [path] is used to derive readable, collision-free helper rule names.
  String bodyFor(Map<String, Object?> schema, String path) {
    final type = schema['type'] as String?;
    switch (type) {
      case 'object':
        return _objectBody(schema, path);
      case 'array':
        return _arrayBody(schema, path);
      case 'string':
        final enumValues = (schema['enum'] as List?)?.cast<String>();
        if (enumValues != null && enumValues.isNotEmpty) {
          final alternatives =
              enumValues.map((v) => '"\\"${_escape(v)}\\""').join(' | ');
          return '($alternatives) space';
        }
        return 'string';
      case 'integer':
        return 'integer';
      case 'number':
        return 'number';
      case 'boolean':
        return 'boolean';
      default:
        return 'value';
    }
  }

  String _objectBody(Map<String, Object?> schema, String path) {
    final properties =
        (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
    if (properties.isEmpty) return '"{" space "}" space';

    final required =
        ((schema['required'] as List?)?.cast<String>() ?? const <String>[])
            .toSet();
    final requiredKeys =
        properties.keys.where(required.contains).toList(growable: false);
    final optionalKeys =
        properties.keys.where((k) => !required.contains(k)).toList(
              growable: false,
            );

    // One `"key" : value` rule per property, so the object body stays flat.
    final kv = <String, String>{};
    for (final key in properties.keys) {
      final propSchema = (properties[key]! as Map).cast<String, Object?>();
      final valueBody = bodyFor(propSchema, '$path-$key');
      final name = _addRule(
        '$path-${_sanitize(key)}-kv',
        '"\\"${_escape(key)}\\"" space ":" space $valueBody',
      );
      kv[key] = name;
    }

    final parts = <String>['"{"', 'space'];
    if (requiredKeys.isNotEmpty) {
      parts.add(kv[requiredKeys.first]!);
      for (final key in requiredKeys.skip(1)) {
        parts.add('"," space ${kv[key]!}');
      }
      for (final key in optionalKeys) {
        parts.add('( "," space ${kv[key]!} )?');
      }
    } else {
      // No required key: any optional key may come first, so enumerate the
      // suffixes (same shape llama.cpp's own converter produces).
      final alternatives = <String>[];
      for (var i = 0; i < optionalKeys.length; i++) {
        final head = kv[optionalKeys[i]]!;
        final tail = optionalKeys
            .skip(i + 1)
            .map((k) => ' ( "," space ${kv[k]!} )?')
            .join();
        alternatives.add('$head$tail');
      }
      parts.add('( ${alternatives.join(' | ')} )?');
    }
    parts
      ..add('"}"')
      ..add('space');
    return parts.join(' ');
  }

  String _arrayBody(Map<String, Object?> schema, String path) {
    final items = (schema['items'] as Map?)?.cast<String, Object?>();
    final itemBody = items == null ? 'value' : bodyFor(items, '$path-item');
    final itemRule = _addRule('$path-item', itemBody);
    return '"[" space ( $itemRule ( "," space $itemRule )* )? "]" space';
  }

  /// Registers [body] under a unique name derived from [preferred].
  String _addRule(String preferred, String body) {
    var name = _sanitize(preferred);
    if (_usedNames.contains(name)) {
      var suffix = 2;
      while (_usedNames.contains('$name-$suffix')) {
        suffix++;
      }
      name = '$name-$suffix';
    }
    _usedNames.add(name);
    _rules[name] = body;
    return name;
  }

  static String _sanitize(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '-');
    return cleaned.isEmpty ? 'rule' : cleaned;
  }

  /// Escapes a literal for use inside a GBNF double-quoted terminal.
  static String _escape(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');

  /// JSON primitives shared by every generated grammar.
  ///
  /// `space` allows at most one space: a `[ \t\n]*` rule lets a constrained
  /// model emit unbounded whitespace and never finish.
  static String _primitives() => '''
value ::= object | array | string | number | boolean | null
object ::= "{" space ( string ":" space value ( "," space string ":" space value )* )? "}" space
array ::= "[" space ( value ( "," space value )* )? "]" space
string ::= "\\"" char* "\\"" space
char ::= [^"\\\\] | "\\\\" ( ["\\\\/bfnrt] | "u" hex hex hex hex )
hex ::= [0-9a-fA-F]
integer ::= "-"? ( [0-9] | [1-9] [0-9]* ) space
number ::= "-"? ( [0-9] | [1-9] [0-9]* ) ( "." [0-9]+ )? ( [eE] [-+]? [0-9]+ )? space
boolean ::= ( "true" | "false" ) space
null ::= "null" space
space ::= " "?
''';
}
