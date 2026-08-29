// lib/application/config/config_notifier.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/config_repository.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_config_validator.dart';
import '../../utils/analytics.dart';
import '../../utils/platform_name.dart';

/// The lowest cached [CaptureConfig.version] still trusted at startup. A
/// returning user's Hive cache is applied BEFORE the remote fetch lands and
/// would otherwise win over the bundled default for the first ~400ms — so a
/// cache written under superseded tuning (e.g. the pre-2026-07-21 equal-thirds
/// tilt bands) is dropped and the bundled default stands until the remote
/// answers. Raise this in lockstep with [CaptureConfig.bundledDefault.version]
/// whenever a bundled change must be authoritative from the first frame.
/// This is a floor, NOT a migration: an old cache is discarded, never rewritten.
const int kMinAcceptedConfigVersion = 4;

/// Owns app-wide capture configuration. [build] returns a synchronous,
/// always-valid value (bundled default) so consumers never see loading/null;
/// it is then upgraded to cached, then remote, via a non-blocking bootstrap.
///
/// Resolution precedence: sanitized remote → sanitized cache → bundled default.
/// The remote fetch is fire-and-forget; failures are silent to the user
/// (analytics only). This notifier is the single sanitization gate — every
/// value reaching state or the cache passes through [sanitizeCaptureConfig].
///
/// A cached config BELOW [kMinAcceptedConfigVersion] is dropped (see there).
class ConfigNotifier extends Notifier<CaptureConfig> {
  @override
  CaptureConfig build() {
    _bootstrap(); // async, non-blocking
    return CaptureConfig.bundledDefault; // immediate, always-valid
  }

  Future<void> _bootstrap() async {
    final repo = ref.read(configRepositoryProvider);
    var usedCache = false;

    // 1) Cache → a better-than-default starting point (instant, offline-safe),
    //    UNLESS it predates the current bundled contract (see
    //    [kMinAcceptedConfigVersion]) — then the bundled default is better.
    try {
      final cached = await repo.readCached();
      if (cached != null && cached.version >= kMinAcceptedConfigVersion) {
        state = sanitizeCaptureConfig(cached);
        usedCache = true;
      }
    } catch (_) {/* corrupt/unreadable cache → stay on bundled default */}

    // 2) Remote refresh in the background; silent on failure (use fallback).
    try {
      final remote = sanitizeCaptureConfig(await repo.fetchRemote());
      state = remote;
      await repo.writeCache(remote);
      _log(result: 'success', sourceUsed: 'remote', version: remote.version);
    } on ConfigParseException {
      _log(
        result: 'parse_error',
        sourceUsed: usedCache ? 'cache' : 'bundled_default',
        version: state.version,
      );
    } catch (_) {
      _log(
        result: 'network_error',
        sourceUsed: usedCache ? 'cache' : 'bundled_default',
        version: state.version,
      );
    }
  }

  /// Re-runs the cache-then-remote bootstrap (e.g. manual refresh).
  Future<void> refresh() => _bootstrap();

  void _log({
    required String result,
    required String sourceUsed,
    required int version,
  }) {
    // Never logs the config payload — only the outcome metadata.
    Analytics.logEvent('remote_config_fetch', {
      'result': result,
      'source_used': sourceUsed,
      'config_version': version,
      'device_type': appPlatformName,
    });
  }
}

/// App-wide capture config. Always holds a valid, non-empty [CaptureConfig].
final captureConfigProvider =
    NotifierProvider<ConfigNotifier, CaptureConfig>(ConfigNotifier.new);
