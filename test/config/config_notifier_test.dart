// test/config/config_notifier_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/repositories/config_repository.dart';
import 'package:recapture/domain/entities/capture_config.dart';

CaptureConfig _config({required int version, int firstBandSegments = 12}) =>
    CaptureConfig(
      version: version,
      pitchBands: [
        PitchBand(
            id: 'low', minDegrees: 0, maxDegrees: 30, segments: firstBandSegments),
      ],
      thresholds: CaptureConfig.bundledDefault.thresholds,
    );

/// Controllable config repository double (no Hive / network).
class FakeConfigRepository implements ConfigRepository {
  FakeConfigRepository({this.cached, this.remote, this.remoteError});

  CaptureConfig? cached;
  CaptureConfig? remote;
  Object? remoteError; // when set, fetchRemote throws this

  CaptureConfig? written;
  int fetchCalls = 0;

  @override
  Future<CaptureConfig?> readCached() async => cached;

  @override
  Future<void> writeCache(CaptureConfig config) async => written = config;

  @override
  Future<CaptureConfig> fetchRemote() async {
    fetchCalls++;
    final err = remoteError;
    if (err != null) throw err;
    return remote!;
  }
}

ProviderContainer _container(FakeConfigRepository repo) {
  final c = ProviderContainer(
    overrides: [configRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(c.dispose);
  return c;
}

/// Triggers build + waits for the async bootstrap to settle.
Future<ProviderContainer> _booted(FakeConfigRepository repo) async {
  final c = _container(repo);
  c.read(captureConfigProvider); // build() → bundled default, kicks off bootstrap
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return c;
}

void main() {
  test('build() returns bundled default synchronously', () {
    final c = _container(FakeConfigRepository(remote: _config(version: 1)));
    expect(c.read(captureConfigProvider).version, 0); // bundled, before bootstrap
  });

  test('no cache + remote success → remote applied and cached', () async {
    final repo = FakeConfigRepository(remote: _config(version: 7));
    final c = await _booted(repo);
    expect(c.read(captureConfigProvider).version, 7);
    expect(repo.written?.version, 7);
  });

  test('cache present + remote failure → ends on cache, no cache write', () async {
    final repo = FakeConfigRepository(
      cached: _config(version: 5),
      remoteError: Exception('offline'),
    );
    final c = await _booted(repo);
    expect(c.read(captureConfigProvider).version, 5);
    expect(repo.written, isNull);
  });

  test('no cache + remote failure → stays on bundled default', () async {
    final repo = FakeConfigRepository(remoteError: Exception('offline'));
    final c = await _booted(repo);
    expect(c.read(captureConfigProvider).version, 0);
    expect(repo.written, isNull);
  });

  test('parse error → stays on fallback, never throws', () async {
    final repo = FakeConfigRepository(
      remoteError: const ConfigParseException('bad payload'),
    );
    final c = await _booted(repo);
    expect(c.read(captureConfigProvider).version, 0); // bundled fallback
    expect(repo.fetchCalls, 1);
  });

  test('out-of-range remote is sanitized before reaching state/cache', () async {
    final repo = FakeConfigRepository(
      remote: CaptureConfig(
        version: 9,
        pitchBands: const [
          PitchBand(id: 'a', minDegrees: -50, maxDegrees: 200, segments: 999),
        ],
        thresholds: const CaptureThresholds(
          minSharpness: 5,
          minCoveragePct: 300,
          maxTiltDeltaDeg: 999,
        ),
      ),
    );
    final c = await _booted(repo);
    final cfg = c.read(captureConfigProvider);
    final band = cfg.pitchBands.single;
    expect(band.minDegrees, 0);
    expect(band.maxDegrees, 90);
    expect(band.segments, 64);
    expect(cfg.thresholds.minSharpness, 1);
    expect(cfg.thresholds.minCoveragePct, 100);
    expect(cfg.thresholds.maxTiltDeltaDeg, 45);
    // Cache receives the sanitized config, never the raw out-of-range payload.
    expect(repo.written?.pitchBands.single.segments, 64);
  });

  test('cache then remote: ends on remote (server authoritative)', () async {
    final repo = FakeConfigRepository(
      cached: _config(version: 5),
      remote: _config(version: 2), // lower version still wins (no downgrade guard)
    );
    final c = await _booted(repo);
    expect(c.read(captureConfigProvider).version, 2);
    expect(repo.written?.version, 2);
  });
}
