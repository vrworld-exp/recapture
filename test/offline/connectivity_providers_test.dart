// test/offline/connectivity_providers_test.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/platform/connectivity_watcher.dart';

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('isOnlineProvider defaults to online before status resolves', () {
    final conn = StreamController<AppConnectivityStatus>();
    addTearDown(conn.close);
    final c = ProviderContainer(overrides: [
      connectivityStatusProvider.overrideWith((ref) => conn.stream),
    ]);
    addTearDown(c.dispose);

    // No event yet → must NOT flash false-offline.
    expect(c.read(isOnlineProvider), isTrue);
  });

  test('isOnlineProvider reflects offline then online', () async {
    final conn = StreamController<AppConnectivityStatus>.broadcast();
    addTearDown(conn.close);
    final c = ProviderContainer(overrides: [
      connectivityStatusProvider.overrideWith((ref) => conn.stream),
    ]);
    addTearDown(c.dispose);

    final sub = c.listen(isOnlineProvider, (_, __) {}); // keep it alive
    addTearDown(sub.close);

    conn.add(AppConnectivityStatus.offline);
    await _settle();
    expect(c.read(isOnlineProvider), isFalse);

    conn.add(AppConnectivityStatus.online);
    await _settle();
    expect(c.read(isOnlineProvider), isTrue);
  });
}
