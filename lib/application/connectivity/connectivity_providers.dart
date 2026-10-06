// lib/application/connectivity/connectivity_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/connectivity_watcher.dart';

/// The single [ConnectivityWatcher] (wraps connectivity_plus). Wrapped, never
/// reimplemented — this is the only place app-wide connectivity state is sourced.
final connectivityWatcherProvider =
    Provider<ConnectivityWatcher>((ref) => ConnectivityWatcher());

/// Live connectivity status, seeded with the current status so the first read
/// isn't stuck on `loading`/unknown. Backed by the watcher's broadcast stream.
final connectivityStatusProvider =
    StreamProvider<AppConnectivityStatus>((ref) async* {
  final watcher = ref.watch(connectivityWatcherProvider);
  yield await watcher.currentStatus(); // immediate seed
  yield* watcher.statusStream; // subsequent changes
});

/// Convenience boolean. Defaults to ONLINE before the status resolves, so the UI
/// never flashes a false "offline" on startup.
///
/// NOTE: "online" means a network interface exists — NOT that the API is
/// reachable. The offline queue's drain result is the real reachability signal;
/// do not treat this flag as proof the backend can be reached.
final isOnlineProvider = Provider<bool>((ref) {
  final async = ref.watch(connectivityStatusProvider);
  return async.maybeWhen(
    data: (s) => s == AppConnectivityStatus.online,
    orElse: () => true,
  );
});

/// Live network TYPE (unmetered / metered / none) — drives the auto-upload
/// policy for captures waiting on the phone. Same single watcher, seeded the
/// same way. Before it resolves it reads as [AppNetworkType.metered]: the
/// conservative guess, so a big capture never starts on mobile data by accident.
final networkTypeProvider = StreamProvider<AppNetworkType>((ref) async* {
  final watcher = ref.watch(connectivityWatcherProvider);
  yield await watcher.currentNetworkType();
  yield* watcher.networkTypeStream;
});

/// [networkTypeProvider] resolved to a value (metered until known).
final currentNetworkTypeProvider = Provider<AppNetworkType>((ref) {
  return ref.watch(networkTypeProvider).maybeWhen(
        data: (t) => t,
        orElse: () => AppNetworkType.metered,
      );
});
