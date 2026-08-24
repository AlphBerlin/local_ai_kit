/// App lifecycle observer driving the runtime's background trim.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Lifecycle phases relevant to resource management.
enum AppLifecyclePhase { foreground, background }

/// Broadcasts foreground/background transitions.
///
/// `RuntimeScheduler` subscribes and unloads all unlocked models when the
/// app backgrounds (when `RuntimeMemoryPolicy.trimOnBackground` is set).
class AppLifecycleObserver {
  AppLifecycleObserver() {
    _bindingObserver = _Observer(_onPhase);
    WidgetsBinding.instance.addObserver(_bindingObserver);
  }

  late final _Observer _bindingObserver;
  final _controller = StreamController<AppLifecyclePhase>.broadcast();

  /// Broadcast stream of lifecycle phases.
  Stream<AppLifecyclePhase> get phases => _controller.stream;

  void _onPhase(AppLifecyclePhase phase) {
    if (!_controller.isClosed) _controller.add(phase);
  }

  /// Detaches from the widgets binding.
  void dispose() {
    WidgetsBinding.instance.removeObserver(_bindingObserver);
    _controller.close();
  }
}

class _Observer extends WidgetsBindingObserver {
  _Observer(this.onPhase);

  final void Function(AppLifecyclePhase phase) onPhase;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onPhase(AppLifecyclePhase.foreground);
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        onPhase(AppLifecyclePhase.background);
    }
  }
}
