// lib/platform/connectivity_watcher.dart
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// UI-facing connectivity status. Widgets consume this only — the raw
/// connectivity_plus types never leave this file.
enum AppConnectivityStatus { online, offline }

/// Thin wrapper over connectivity_plus. The single place that knows about the
/// package — swap the mapping here and widget code keeps working.
///
/// NOTE: "online" only means a network interface exists, not that the API is
/// reachable. A failed retry callback is the real source of truth for whether
/// the app can actually reach the backend — see [OfflineRetryModal].
class ConnectivityWatcher {
  ConnectivityWatcher([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  Stream<AppConnectivityStatus> get statusStream =>
      _connectivity.onConnectivityChanged.map(_map);

  Future<AppConnectivityStatus> currentStatus() async =>
      _map(await _connectivity.checkConnectivity());

  // connectivity_plus returns a List<ConnectivityResult> in v3+, but older
  // versions returned a single value — handle both. Offline only when every
  // reported interface is `none`.
  AppConnectivityStatus _map(dynamic result) {
    final results = result is List ? result : [result];
    final hasConnection = results.any((r) => r != ConnectivityResult.none);
    return hasConnection
        ? AppConnectivityStatus.online
        : AppConnectivityStatus.offline;
  }
}
