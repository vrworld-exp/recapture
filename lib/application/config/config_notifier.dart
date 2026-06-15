// lib/application/config/config_notifier.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/config_repository.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_config_validator.dart';
import '../../utils/analytics.dart';

/// Owns app-wide capture configuration. [build] returns a synchronous,
/// always-valid value (bundled default) so consumers never see loading/null;
/// it is then upgraded to cached, then remote, via a non-blocking bootstrap.
///
/// Resolution precedence: sanitized remote → sanitized cache → bundled default.
/// The remote fetch is fire-and-forget; failures are silent to the user
/// (analytics only). This notifier is the single sanitization gate — every
/// value reaching state or the cache passes through [sanitizeCaptureConfig].
class ConfigNotifier extends Notifier<CaptureConfig> {
  @override
  CaptureConfig build() {
    _bootstrap(); // async, non-blocking
    return CaptureConfig.bundledDefault; // immediate, always-valid
  }

  Future<void> _bootstrap() async {
    final repo = ref.read(configRepositoryProvider);
    var usedCache = false;

    // 1) Cache → a better-than-default starting point (instant, offline-safe).
    try {
      final cached = await repo.readCached();
      if (cached != null) {
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
      'device_type':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });
  }
}

/// App-wide capture config. Always holds a valid, non-empty [CaptureConfig].
final captureConfigProvider =
    NotifierProvider<ConfigNotifier, CaptureConfig>(ConfigNotifier.new);
