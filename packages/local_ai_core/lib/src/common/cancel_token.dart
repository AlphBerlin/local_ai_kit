/// Cooperative cancellation primitive shared by pipelines, voice sessions
/// and download tasks.
library;

import '../errors/local_ai_error.dart';

/// A token that can be cancelled once and observed by many listeners.
///
/// Unlike [Future] cancellation, a [CancelToken] never completes a stream by
/// itself; producers are expected to poll [isCancelled] (or call
/// [throwIfCancelled]) at chunk boundaries and stop emitting.
class CancelToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// Whether [cancel] has been called.
  bool get isCancelled => _isCancelled;

  /// Cancels the token. Idempotent: subsequent calls are no-ops.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    // Copy: listeners may remove themselves while being notified.
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  /// Throws [CancelledError] if this token has been cancelled.
  void throwIfCancelled() {
    if (_isCancelled) throw const CancelledError();
  }

  /// Registers [listener] to run once on cancellation.
  ///
  /// If the token is already cancelled the listener runs synchronously.
  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  /// Removes a previously registered [listener].
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Returns a child token that is cancelled when this token is cancelled.
  ///
  /// Cancelling the child does not cancel the parent. Used to scope
  /// per-stage cancellation inside a pipeline.
  CancelToken child() {
    final child = CancelToken();
    addListener(child.cancel);
    return child;
  }
}
