// test/capture/stability_provider_test.dart
//
// Verifies the stability provider maps the EXISTING native stability-gate stream
// to a coarse [StabilitySample]: debounced state events → stable/unstable, the
// continuous score + auto-capture trigger events are ignored (they are not the
// label), and a stream error (absent sensor) degrades to an unsupported/unknown
// sample rather than an AsyncError. The native gate is injected via
// [stabilityEventSourceProvider] — no platform channels.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/platform/stability_channel.dart';

StabilityStateEvent _state(bool stable) => StabilityStateEvent(
      stable: stable,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    );

void main() {
  late StreamController<StabilityEvent> source;
  late ProviderContainer container;
  late List<StabilitySample> samples;
  late ProviderSubscription<AsyncValue<StabilitySample>> sub;

  setUp(() {
    source = StreamController<StabilityEvent>.broadcast();
    container = ProviderContainer(overrides: [
      stabilityEventSourceProvider.overrideWithValue(source.stream),
    ]);
    samples = [];
    sub = container.listen<AsyncValue<StabilitySample>>(
      stabilityProvider,
      (_, next) {
        final v = next.asData?.value;
        if (v != null) samples.add(v);
      },
      fireImmediately: true,
    );
  });

  tearDown(() async {
    sub.close();
    container.dispose();
    await source.close();
  });

  test('a stable state event → Stability.stable (supported)', () async {
    source.add(_state(true));
    await pumpEventQueue();
    expect(samples.single.stability, Stability.stable);
    expect(samples.single.sensorSupported, isTrue);
  });

  test('an unstable state event → Stability.unstable', () async {
    source.add(_state(false));
    await pumpEventQueue();
    expect(samples.single.stability, Stability.unstable);
  });

  test('score and trigger events are ignored (not the label)', () async {
    source.add(const StabilityScoreEvent(
      score: 0.9,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    ));
    source.add(const StabilityTriggerEvent(timestampNs: 0));
    await pumpEventQueue();
    expect(samples, isEmpty);

    source.add(_state(true));
    await pumpEventQueue();
    expect(samples.single.stability, Stability.stable);
  });

  test('a stream error degrades to unknown/unsupported (no AsyncError)',
      () async {
    source.addError(Exception('STABILITY_UNAVAILABLE'));
    await pumpEventQueue();
    expect(samples.single.stability, Stability.unknown);
    expect(samples.single.sensorSupported, isFalse);
    expect(container.read(stabilityProvider).hasError, isFalse);
  });

  test('tracks transitions over time (stable → unstable → stable)', () async {
    source.add(_state(true));
    await pumpEventQueue();
    source.add(_state(false));
    await pumpEventQueue();
    source.add(_state(true));
    await pumpEventQueue();
    expect(
      samples.map((s) => s.stability),
      [Stability.stable, Stability.unstable, Stability.stable],
    );
  });
}
