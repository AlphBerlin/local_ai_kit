/// Minimal, dependency-free JSON Schema model used for structured output.
///
/// Supports the subset that makes sense for on-device constrained output:
/// `type`, `properties`, `required`, `items`, `enum`, `description`,
/// `additionalProperties`. It is serializable (for prompt injection) and
/// ships a small validator used by the retry loop.
library;

/// A JSON Schema document (subset).
class JsonSchema {
  const JsonSchema._(this.schema);

  final Map<String, Object?> schema;

  /// Wraps an already-built schema map.
  factory JsonSchema.fromMap(Map<String, Object?> schema) =>
      JsonSchema._(Map<String, Object?>.unmodifiable(schema));

  /// Convenience builder for an object schema.
  factory JsonSchema.object({
    Map<String, JsonSchema> properties = const {},
    List<String> required = const [],
    String? description,
  }) {
    return JsonSchema._(<String, Object?>{
      'type': 'object',
      if (description != null) 'description': description,
      'properties': <String, Object?>{
        for (final entry in properties.entries) entry.key: entry.value.schema,
      },
      'required': required,
      'additionalProperties': false,
    });
  }

  factory JsonSchema.string({String? description, List<String>? enumValues}) =>
      JsonSchema._(<String, Object?>{
        'type': 'string',
        if (description != null) 'description': description,
        if (enumValues != null) 'enum': enumValues,
      });

  factory JsonSchema.number({String? description}) =>
      JsonSchema._(<String, Object?>{
        'type': 'number',
        if (description != null) 'description': description
      });

  factory JsonSchema.integer({String? description}) =>
      JsonSchema._(<String, Object?>{
        'type': 'integer',
        if (description != null) 'description': description
      });

  factory JsonSchema.boolean({String? description}) =>
      JsonSchema._(<String, Object?>{
        'type': 'boolean',
        if (description != null) 'description': description
      });

  factory JsonSchema.array({required JsonSchema items, String? description}) =>
      JsonSchema._(<String, Object?>{
        'type': 'array',
        'items': items.schema,
        if (description != null) 'description': description,
      });

  /// Raw schema map (safe to pass to `jsonEncode`).
  Map<String, Object?> toMap() => schema;

  /// Pretty-printed schema used for prompt injection when the runtime has no
  /// grammar / constrained-decoding support.
  String toPromptString() => _pretty(schema);

  static String _pretty(Object? value, [int indent = 0]) {
    final pad = '  ' * indent;
    final childPad = '  ' * (indent + 1);
    if (value is Map) {
      final entries = value.entries
          .map((e) => '$childPad"${e.key}": ${_pretty(e.value, indent + 1)}')
          .join(',\n');
      return '{\n$entries\n$pad}';
    }
    if (value is List) {
      if (value.isEmpty) return '[]';
      final items =
          value.map((e) => '$childPad${_pretty(e, indent + 1)}').join(',\n');
      return '[\n$items\n$pad]';
    }
    if (value is String) return '"$value"';
    return '$value';
  }

  /// Validates [value] against this schema subset.
  ///
  /// Returns `null` when valid, otherwise a human-readable reason. This is a
  /// best-effort validator for the retry loop, not a full JSON Schema impl.
  String? validate(Object? value) => _validateAgainst(schema, value, r'$');

  static String? _validateAgainst(
      Map<String, Object?> schema, Object? value, String path) {
    final type = schema['type'] as String?;
    switch (type) {
      case 'object':
        if (value is! Map) {
          return '$path: expected object, got ${_typeOf(value)}';
        }
        final props = schema['properties'] as Map<String, Object?>? ?? const {};
        final required =
            (schema['required'] as List?)?.cast<String>() ?? const [];
        for (final key in required) {
          if (!value.containsKey(key)) {
            return '$path: missing required key "$key"';
          }
        }
        final allowAdditional = schema['additionalProperties'] != false;
        for (final entry in value.entries) {
          final propSchema = props[entry.key];
          if (propSchema == null) {
            if (!allowAdditional) return '$path: unexpected key "${entry.key}"';
            continue;
          }
          final error = _validateAgainst(
              (propSchema as Map).cast<String, Object?>(),
              entry.value,
              '$path.${entry.key}');
          if (error != null) return error;
        }
        return null;
      case 'array':
        if (value is! List) {
          return '$path: expected array, got ${_typeOf(value)}';
        }
        final itemSchema = schema['items'] as Map<String, Object?>?;
        if (itemSchema != null) {
          for (var i = 0; i < value.length; i++) {
            final error = _validateAgainst(itemSchema, value[i], '$path[$i]');
            if (error != null) return error;
          }
        }
        return null;
      case 'string':
        if (value is! String) {
          return '$path: expected string, got ${_typeOf(value)}';
        }
        final enumValues = (schema['enum'] as List?)?.cast<String>();
        if (enumValues != null && !enumValues.contains(value)) {
          return '$path: "$value" not in enum $enumValues';
        }
        return null;
      case 'integer':
        if (value is! int) {
          return '$path: expected integer, got ${_typeOf(value)}';
        }
        return null;
      case 'number':
        if (value is! num) {
          return '$path: expected number, got ${_typeOf(value)}';
        }
        return null;
      case 'boolean':
        if (value is! bool) {
          return '$path: expected boolean, got ${_typeOf(value)}';
        }
        return null;
      default:
        return null; // Unknown / absent type: accept.
    }
  }

  static String _typeOf(Object? value) {
    if (value == null) return 'null';
    if (value is Map) return 'object';
    if (value is List) return 'array';
    if (value is String) return 'string';
    if (value is bool) return 'boolean';
    if (value is num) return 'number';
    return value.runtimeType.toString();
  }
}
