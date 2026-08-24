/// Runtime permission requests (microphone, storage).
library;

import 'dart:async';
import 'package:local_ai_core/local_ai_core.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thin wrapper over `permission_handler` mapping denials onto core errors.
class PermissionGate {
  /// Ensures microphone access; throws [InvalidStateError] when denied.
  Future<void> ensureMicrophone() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw const InvalidStateError(
        'Microphone permission denied. Grant it in system settings to use '
        'voice features.',
      );
    }
  }

  /// Whether microphone permission is currently granted.
  Future<bool> hasMicrophone() async =>
      (await Permission.microphone.status).isGranted;

  /// Opens the system settings page (for permanently denied permissions).
  Future<bool> openSettings() => openAppSettings();
}