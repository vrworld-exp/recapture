// lib/platform/connectivity_watcher.dart
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// UI-facing connectivity status. Widgets consume this only — the raw
/// connectivity_plus types never leave this file.
enum AppConnectivityStatus { online, offline }

/// What KIND of network is up — the input to the "Full captures wait for Wi-Fi"
/// rule. [unmetered] covers Wi-Fi and Ethernet; [metered] is mobile data (and
/// anything else we cannot prove is unmetered — a VPN or Bluetooth tether over
/// mobile data must not be mistaken for Wi-Fi); [none] means no interface.
enum AppNetworkType { unmetered, metered, none }

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

  /// The network TYPE as it changes. Same source as [statusStream].
  Stream<AppNetworkType> get networkTypeStream =>
      _connectivity.onConnectivityChanged.map(_mapType);

  Future<AppNetworkType> currentNetworkType() async =>
      _mapType(await _connectivity.checkConnectivity());

  AppNetworkType _mapType(dynamic result) {
    final results = result is List ? result : [result];
    if (results.any((r) =>
        r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet)) {
      return AppNetworkType.unmetered;
    }
    if (results.any((r) => r != ConnectivityResult.none)) {
      return AppNetworkType.metered;
    }
    return AppNetworkType.none;
  }

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
