/// Testable clock abstraction.
library;

/// Source of wall-clock time. Inject fakes in tests; production code uses
/// [Clock.system].
abstract interface class Clock {
  DateTime now();

  /// The real wall clock.
  static const Clock system = _SystemClock();
}

class _SystemClock implements Clock {
  const _SystemClock();

  @override
  DateTime now() => DateTime.now();
}
