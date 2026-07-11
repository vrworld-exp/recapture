// test/config/pitch_band_resolver_provider_test.dart
//
// The reactive resolver wiring: resolvedPitchBandProvider applies override →
// remote/cache → bundled default off the live config + override providers, and
// logs a `pitch_band_fallback` diagnostic on rejection. Plus the override store.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/pitch_band_override_provider.dart';
import 'package:recapture/application/capture/pitch_band_resolver.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/utils/analytics.dart';

PitchBand _band(String id, double min, double max) =>
    PitchBand(id: id, minDegrees: min, maxDegrees: max, segments: 8);

class _StubConfig extends ConfigNotifier {
  _StubConfig(this._cfg);
  final CaptureConfig _cfg;
  @override
  CaptureConfig build() => _cfg;
}

ProviderContainer _container({CaptureConfig? config}) {
  final c = ProviderContainer(overrides: [
    captureConfigProvider.overrideWith(
        () => _StubConfig(config ?? CaptureConfig.bundledDefault)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('PitchBandOverrideNotifier', () {
    test('set / clear / clearAll', () {
      final c = _container();
      final n = c.read(pitchBandOverrideProvider.notifier);
      expect(c.read(pitchBandOverrideProvider), isEmpty);

      n.setOverride(_band('low', 5, 25));
      expect(c.read(pitchBandOverrideProvider)['low']!.maxDegrees, 25);

      n.setOverride(_band('low', 1, 29)); // replaces
      expect(c.read(pitchBandOverrideProvider)['low']!.maxDegrees, 29);

      n.clearOverride('low');
      expect(c.read(pitchBandOverrideProvider), isEmpty);

      n.setOverride(_band('high', 60, 90));
      n.clearAll();
      expect(c.read(pitchBandOverrideProvider), isEmpty);
    });
  });

  group('resolvedPitchBandProvider', () {
    test('no override → bundled/remote config value (Level C low = [0,60))', () {
      final c = _container();
      final low = c.read(resolvedPitchBandProvider('low'));
      expect(low.minDegrees, 0);
      expect(low.maxDegrees, 60);
    });

    test('override wins over a valid config value', () {
      final c = _container();
      c.read(pitchBandOverrideProvider.notifier).setOverride(_band('low', 4, 20));
      final low = c.read(resolvedPitchBandProvider('low'));
      expect(low.minDegrees, 4);
      expect(low.maxDegrees, 20);
    });

    test('invalid override is rejected, logs pitch_band_fallback, falls through',
        () {
      final events = <({String name, Map<String, Object?> props})>[];
      Analytics.testSink = (n, p) => events.add((name: n, props: p));
      addTearDown(() => Analytics.testSink = null);

      final c = _container();
      c.read(pitchBandOverrideProvider.notifier)
          .setOverride(_band('low', 40, 10)); // min > max
      final low = c.read(resolvedPitchBandProvider('low'));

      expect(low.maxDegrees, 60); // fell through to config default
      final fb = events.where((e) => e.name == 'pitch_band_fallback').toList();
      expect(fb, hasLength(1));
      expect(fb.first.props['band_id'], 'low');
      expect(fb.first.props['source'], 'override');
      expect(fb.first.props['reason'], 'invalid_override');
    });

    test('held read is a snapshot: a later override does NOT change a prior read',
        () {
      // Mirrors the capture screen holding the band for the pass: read once, then
      // mutate the override — the already-read value is unaffected.
      final c = _container();
      final held = c.read(resolvedPitchBandProvider('low'));
      c.read(pitchBandOverrideProvider.notifier).setOverride(_band('low', 9, 19));
      expect(held.minDegrees, 0); // the snapshot we captured earlier is stable
      expect(held.maxDegrees, 60);
    });
  });
}
