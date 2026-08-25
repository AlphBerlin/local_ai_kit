/// Built-in MCP skills ready to use out of the box.
library;

import 'dart:async';
import 'dart:math' as math;

import '../llm/json_schema.dart';
import 'mcp_plugin.dart';
import 'mcp_types.dart';

/// Evaluates mathematical expressions safely on device.
class CalculatorSkill extends LocalSkill {
  const CalculatorSkill();

  @override
  String get name => 'calculator';

  @override
  String get description =>
      'Performs mathematical and arithmetic calculations safely.';

  @override
  String? get systemPromptSnippet =>
      'Use the calculator tool for any exact math calculations, unit arithmetic, or formula evaluations.';

  @override
  List<McpToolDefinition> get tools => [
        McpToolDefinition(
          name: 'calculate',
          description:
              'Evaluates a mathematical expression (e.g. "45 * (12 + 8)", "sqrt(144)", "2^8").',
          inputSchema: JsonSchema.object(
            properties: {
              'expression': JsonSchema.string(
                description: 'The math expression to evaluate.',
              ),
            },
            required: ['expression'],
          ),
        ),
      ];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (name != 'calculate') {
      return McpToolResult.error(name, 'Unknown tool "$name".');
    }
    final rawExpr = arguments['expression'];
    if (rawExpr is! String || rawExpr.trim().isEmpty) {
      return McpToolResult.error(
          name, 'Missing required string parameter "expression".');
    }

    try {
      final value = _evaluate(rawExpr.trim());
      return McpToolResult.success(
        name,
        '$rawExpr = $value',
        structuredData: {'expression': rawExpr, 'result': value},
      );
    } catch (e) {
      return McpToolResult.error(name, 'Calculation failed: $e');
    }
  }

  static double _evaluate(String expression) {
    // Clean up input
    var expr = expression
        .replaceAll(' ', '')
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('−', '-');

    // Handle simple sqrt(x)
    final sqrtMatch = RegExp(r'sqrt\(([^)]+)\)').firstMatch(expr);
    if (sqrtMatch != null) {
      final innerVal = _evaluate(sqrtMatch.group(1)!);
      expr = expr.replaceRange(
        sqrtMatch.start,
        sqrtMatch.end,
        math.sqrt(innerVal).toString(),
      );
    }

    // Handle parentheses
    while (expr.contains('(')) {
      final match = RegExp(r'\(([^()]+)\)').firstMatch(expr);
      if (match == null) break;
      final inner = _evaluate(match.group(1)!);
      expr = expr.replaceRange(match.start, match.end, inner.toString());
    }

    // Evaluate basic binary expressions +, -, *, /, ^
    return _evalSimple(expr);
  }

  static double _evalSimple(String expr) {
    expr = expr.trim();
    if (expr.isEmpty) return 0.0;

    // 1. Addition & Subtraction (lowest precedence, split on last + or -)
    for (var i = expr.length - 1; i >= 0; i--) {
      final char = expr[i];
      if (char == '+' && i > 0) {
        return _evalSimple(expr.substring(0, i)) +
            _evalSimple(expr.substring(i + 1));
      } else if (char == '-' && i > 0) {
        final prev = expr[i - 1];
        if (prev != '*' && prev != '/' && prev != '^' && prev != 'e' && prev != '+' && prev != '-') {
          return _evalSimple(expr.substring(0, i)) -
              _evalSimple(expr.substring(i + 1));
        }
      }
    }

    // 2. Multiplication, Division & Modulo (medium precedence)
    for (var i = expr.length - 1; i >= 0; i--) {
      final char = expr[i];
      if (char == '*') {
        return _evalSimple(expr.substring(0, i)) *
            _evalSimple(expr.substring(i + 1));
      } else if (char == '/') {
        final divisor = _evalSimple(expr.substring(i + 1));
        if (divisor == 0) throw Exception('Division by zero.');
        return _evalSimple(expr.substring(0, i)) / divisor;
      } else if (char == '%') {
        final divisor = _evalSimple(expr.substring(i + 1));
        if (divisor == 0) throw Exception('Modulo by zero.');
        return _evalSimple(expr.substring(0, i)) % divisor;
      }
    }

    // 3. Exponentiation ^ (high precedence)
    if (expr.contains('^')) {
      final idx = expr.indexOf('^');
      return math.pow(
        _evalSimple(expr.substring(0, idx)),
        _evalSimple(expr.substring(idx + 1)),
      ).toDouble();
    }

    // 4. Parse single number
    return double.parse(expr);
  }
}

/// Provides current time and date information from the local device clock.
class TimeSkill extends LocalSkill {
  const TimeSkill();

  @override
  String get name => 'device_time';

  @override
  String get description =>
      'Retrieves the current local time, UTC timestamp, and day of week.';

  @override
  String? get systemPromptSnippet =>
      'Use the device_time skill to answer questions about the current time, date, day of week, or timezone.';

  @override
  List<McpToolDefinition> get tools => [
        McpToolDefinition(
          name: 'get_current_time',
          description:
              'Returns the current time on the device, including ISO-8601 string, timezone offset, and local date formatting.',
          inputSchema: JsonSchema.object(
            properties: {
              'format': JsonSchema.string(
                description: 'Optional format: "iso", "human", or "date_only".',
                enumValues: ['iso', 'human', 'date_only'],
              ),
            },
          ),
        ),
      ];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (name != 'get_current_time') {
      return McpToolResult.error(name, 'Unknown tool "$name".');
    }

    final now = DateTime.now();
    final format = arguments['format'] as String? ?? 'human';
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    final weekdayName = weekdays[now.weekday - 1];

    final summary = switch (format) {
      'iso' => now.toIso8601String(),
      'date_only' =>
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ($weekdayName)',
      _ =>
        '$weekdayName, ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} (UTC${now.timeZoneOffset.isNegative ? '' : '+'}${now.timeZoneOffset.inHours}h)',
    };

    return McpToolResult.success(
      name,
      summary,
      structuredData: {
        'iso': now.toIso8601String(),
        'year': now.year,
        'month': now.month,
        'day': now.day,
        'hour': now.hour,
        'minute': now.minute,
        'weekday': weekdayName,
        'timezoneOffsetHours': now.timeZoneOffset.inHours,
      },
    );
  }
}

/// Provides system and hardware capabilities information.
class DeviceInfoSkill extends LocalSkill {
  const DeviceInfoSkill({this.platformOverride});

  final String? platformOverride;

  @override
  String get name => 'device_info';

  @override
  String get description =>
      'Retrieves device specifications, operating system, and hardware status.';

  @override
  List<McpToolDefinition> get tools => [
        McpToolDefinition(
          name: 'get_device_info',
          description:
              'Returns current device environment details and capabilities.',
          inputSchema: JsonSchema.object(),
        ),
      ];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (name != 'get_device_info') {
      return McpToolResult.error(name, 'Unknown tool "$name".');
    }

    final info = {
      'platform': platformOverride ?? 'local_ai_device',
      'runtime': 'Flutter / Dart',
      'onDeviceAcceleration': 'GPU / NPU (Supported)',
      'offlineReady': true,
      'memoryStatus': 'Normal',
    };

    return McpToolResult.success(
      name,
      'Device Specs:\n'
      '- Platform: ${info['platform']}\n'
      '- Runtime: ${info['runtime']}\n'
      '- On-device Acceleration: ${info['onDeviceAcceleration']}\n'
      '- Offline Ready: ${info['offlineReady']}',
      structuredData: info,
    );
  }
}

/// Provides simulated/mock weather information for cities.
class WeatherSkill extends LocalSkill {
  const WeatherSkill();

  @override
  String get name => 'weather';

  @override
  String get description =>
      'Looks up current weather conditions, temperature, and forecasts.';

  @override
  List<McpToolDefinition> get tools => [
        McpToolDefinition(
          name: 'get_weather',
          description: 'Gets current weather details for a specific city.',
          inputSchema: JsonSchema.object(
            properties: {
              'city': JsonSchema.string(description: 'City name (e.g. Tokyo, London, San Francisco)'),
              'unit': JsonSchema.string(
                description: 'Temperature unit: "celsius" or "fahrenheit".',
                enumValues: ['celsius', 'fahrenheit'],
              ),
            },
            required: ['city'],
          ),
        ),
      ];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (name != 'get_weather') {
      return McpToolResult.error(name, 'Unknown tool "$name".');
    }

    final city = arguments['city'] as String? ?? 'Unknown';
    final unit = arguments['unit'] as String? ?? 'celsius';

    // Predictable mock temperature based on city hash
    final hash = city.codeUnits.fold(0, (a, b) => a + b);
    final tempC = 15 + (hash % 15);
    final temp = unit == 'fahrenheit' ? (tempC * 9 / 5 + 32).round() : tempC;
    final conditions = ['Sunny', 'Partly Cloudy', 'Clear Sky', 'Breezy', 'Light Rain'];
    final condition = conditions[hash % conditions.length];
    final humidity = 40 + (hash % 40);

    return McpToolResult.success(
      name,
      'Weather for $city:\n'
      'Condition: $condition\n'
      'Temperature: $temp°${unit == 'fahrenheit' ? 'F' : 'C'}\n'
      'Humidity: $humidity%',
      structuredData: {
        'city': city,
        'condition': condition,
        'temperature': temp,
        'unit': unit,
        'humidity': humidity,
      },
    );
  }
}
