import 'dart:async';
import 'package:flutter/foundation.dart';

enum LogLevel { info, success, warning, error }

class LogEntry {
  const LogEntry({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.details,
  });

  final int id;
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final String? details;

  String formatTime() {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

class AppLogger {
  AppLogger._();

  static int _nextId = 1;
  static final List<LogEntry> _logs = [];
  static final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();

  static ValueNotifier<int> errorCountNotifier = ValueNotifier<int>(0);

  static List<LogEntry> get logs => List.unmodifiable(_logs);
  static Stream<List<LogEntry>> get stream => _controller.stream;

  static void log(
    LogLevel level,
    String tag,
    String message, {
    String? details,
  }) {
    final entry = LogEntry(
      id: _nextId++,
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      details: details,
    );
    _logs.add(entry);
    if (level == LogLevel.error) {
      errorCountNotifier.value++;
    }
    if (_logs.length > 500) {
      _logs.removeAt(0);
    }
    _controller.add(_logs);
    debugPrint('[${entry.formatTime()}] [${entry.tag}] ${entry.message}');
  }

  static void info(String tag, String message, {String? details}) =>
      log(LogLevel.info, tag, message, details: details);

  static void success(String tag, String message, {String? details}) =>
      log(LogLevel.success, tag, message, details: details);

  static void warn(String tag, String message, {String? details}) =>
      log(LogLevel.warning, tag, message, details: details);

  static void error(String tag, String message, {Object? error, StackTrace? stackTrace}) {
    final details = StringBuffer();
    if (error != null) details.writeln('Error: $error');
    if (stackTrace != null) details.writeln('StackTrace:\n$stackTrace');
    log(
      LogLevel.error,
      tag,
      message,
      details: details.isNotEmpty ? details.toString() : null,
    );
  }

  static void clear() {
    _logs.clear();
    errorCountNotifier.value = 0;
    _controller.add(_logs);
  }
}
