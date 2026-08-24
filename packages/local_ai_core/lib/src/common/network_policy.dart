/// Network policy abstraction used by the download manager.
library;

import 'dart:async';

/// Coarse network reachability / transport classification.
enum NetworkStatus {
  /// Connected over Wi-Fi (or ethernet).
  wifi,

  /// Connected over a metered cellular link.
  cellular,

  /// No connectivity.
  offline,

  /// Could not be determined (desktop, permission missing, ...).
  unknown,
}

/// Decides whether a model download may start right now.
///
/// Implemented by `local_ai_flutter` on top of connectivity_plus; core only
/// depends on this interface so the download manager stays pure Dart.
abstract interface class NetworkPolicy {
  /// Whether a (potentially large) download is allowed under [wifiOnly].
  Future<bool> canDownload({bool wifiOnly = true});

  /// Current best-effort status snapshot.
  Future<NetworkStatus> currentStatus();

  /// Emits when the transport changes (wifi -> cellular etc.). The download
  /// manager subscribes to resume `queued` downloads when Wi-Fi returns.
  Stream<NetworkStatus> get onStatusChanged;
}
