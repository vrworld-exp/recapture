// lib/data/repositories/config_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/capture_config.dart';
import '../local/config_cache_box.dart';
import '../local/storage_providers.dart';

/// Thrown when a remote config payload is structurally unusable (e.g. not a JSON
/// object). Lets the notifier report `parse_error` distinctly from a network
/// failure. Field-level issues are handled defensively by `fromMap`/sanitizer,
/// not by throwing.
class ConfigParseException implements Exception {
  const ConfigParseException(this.message);
  final String message;
  @override
  String toString() => 'ConfigParseException: $message';
}

/// Remote + cache access for capture config. The notifier is the single
/// sanitization gate, so this layer only parses and does raw cache I/O.
abstract interface class ConfigRepository {
  /// Fetches and parses the remote config. Throws on network error;
  /// throws [ConfigParseException] on a structurally invalid payload.
  Future<CaptureConfig> fetchRemote();

  /// Returns the cached config, or null when absent/corrupt.
  Future<CaptureConfig?> readCached();

  /// Writes the (already-sanitized) config to the cache.
  Future<void> writeCache(CaptureConfig config);
}

/// Concrete [ConfigRepository] backed by the recapture-api config endpoint and
/// the `config_cache` Hive box.
///
/// TODO(api): `fetchRemote` is stubbed (no central Dio client consumes
/// `dioProvider` yet). Replace with the real call, e.g.:
/// ```dart
/// final res = await dio.get('/config/capture');
/// final data = res.data;
/// if (data is! Map<String, dynamic>) {
///   throw const ConfigParseException('not an object');
/// }
/// return CaptureConfig.fromMap(data);
/// ```
/// Config is app-level (not user-scoped), so the endpoint does not require auth.
class RemoteConfigRepository implements ConfigRepository {
  const RemoteConfigRepository(this._cache);

  final ConfigCacheBox _cache;

  @override
  Future<CaptureConfig> fetchRemote() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // Stubbed remote payload (version 5) — distinct from, and above, the
    // bundled default (version 4) so the remote-applied path stays observable
    // end-to-end. Bands MUST track the bundled defaults: this stub always
    // succeeds, so a stale copy here silently overwrites them ~400ms after
    // launch. Bands are on the 0–180° camera-tilt scale, matching the
    // backend's served shape (recapture-api remoteConfigSchema.ts — same
    // `minDegrees`/`maxDegrees` keys, no wire mapping needed).
    return CaptureConfig.fromMap(const {
      'version': 5,
      'pitchBands': [
        {'id': 'low', 'minDegrees': 0, 'maxDegrees': 40, 'segments': 14},
        {'id': 'mid', 'minDegrees': 40, 'maxDegrees': 110, 'segments': 12},
        {'id': 'high', 'minDegrees': 110, 'maxDegrees': 180, 'segments': 10},
      ],
      'thresholds': {
        'minSharpness': 0.5,
        'minCoveragePct': 85,
        'maxTiltDeltaDeg': 10,
      },
    });
  }

  @override
  Future<CaptureConfig?> readCached() => _cache.read();

  @override
  Future<void> writeCache(CaptureConfig config) => _cache.save(config);
}

/// App-wide config repository.
final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) => RemoteConfigRepository(ref.read(configCacheBoxProvider)),
);
