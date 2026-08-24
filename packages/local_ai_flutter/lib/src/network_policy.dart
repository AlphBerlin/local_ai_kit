/// connectivity_plus backed [NetworkPolicy].
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:local_ai_core/local_ai_core.dart';

/// Maps connectivity_plus results onto core's [NetworkStatus].
class FlutterNetworkPolicy implements NetworkPolicy {
  FlutterNetworkPolicy({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> canDownload({bool wifiOnly = true}) async {
    final status = await currentStatus();
    switch (status) {
      case NetworkStatus.wifi:
        return true;
      case NetworkStatus.cellular:
        return !wifiOnly;
      case NetworkStatus.unknown:
        // Fail open on unknown (desktop, missing permission): the download
        // itself will surface real network failures.
        return true;
      case NetworkStatus.offline:
        return false;
    }
  }

  @override
  Future<NetworkStatus> currentStatus() async {
    final results = await _connectivity.checkConnectivity();
    return _map(results);
  }

  @override
  Stream<NetworkStatus> get onStatusChanged =>
      _connectivity.onConnectivityChanged.map(_map);

  static NetworkStatus _map(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return NetworkStatus.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkStatus.cellular;
    }
    if (results.contains(ConnectivityResult.none) || results.isEmpty) {
      return NetworkStatus.offline;
    }
    return NetworkStatus.unknown;
  }
}
