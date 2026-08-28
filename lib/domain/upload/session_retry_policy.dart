// lib/domain/upload/session_retry_policy.dart
//
// Pure Dart — NO Flutter / IO. The SESSION-level automatic-retry policy: how many
// times a whole upload attempt is retried on a transient failure, and the backoff
// schedule between attempts (exponential + jitter, `Retry-After`-aware, capped).
//
// DISTINCT from the PART-level [UploadRetryPolicy] (upload_part_plan.dart): that
// retries a single S3 part PUT WITHIN one attempt; THIS retries the whole session
// attempt (initiate → parts → complete) AFTER the part-level retries are exhausted.
// The two compose and must not be conflated.
//
// HARD CAP: [maxRetries] can never exceed [hardMaxRetries] (3 → 4 total attempts),
// enforced in code regardless of remote config. Invalid config falls back to the
// bundled defaults (logged via the [onFallback] hook), never throwing.
import 'dart:math' as math;

/// Backoff jitter strategy.
enum RetryJitter {
  /// No jitter — the exact computed delay.
  none,

  /// Full jitter — a uniform random value in `(0, computed]` (spreads retries so
  /// many clients don't reconnect in lock-step).
  full;

  static RetryJitter fromWire(Object? raw) =>
      raw == 'none' ? RetryJitter.none : RetryJitter.full;

  String get wire => name;
}

/// The session-retry policy (config-driven, validated, hard-capped).
class SessionRetryPolicy {
  const SessionRetryPolicy({
    this.maxRetries = kDefaultMaxRetries,
    this.baseDelay = const Duration(seconds: 1),
    this.multiplier = 2.0,
    this.maxDelay = const Duration(seconds: 30),
    this.jitter = RetryJitter.full,
  });

  /// Default retries after the initial attempt (→ 4 total attempts).
  static const int kDefaultMaxRetries = 3;

  /// The absolute upper bound on retries — the cap is HARD even if remote config
  /// asks for more.
  static const int hardMaxRetries = 3;

  /// The bundled default policy.
  static const SessionRetryPolicy bundledDefault = SessionRetryPolicy();

  /// Retries after the first attempt. Always in `[0, hardMaxRetries]`.
  final int maxRetries;
  final Duration baseDelay;
  final double multiplier;
  final Duration maxDelay;
  final RetryJitter jitter;

  /// Total attempts = 1 initial + [maxRetries].
  int get maxAttempts => maxRetries + 1;

  /// The backoff before the retry at [retryIndex] (0-based: 0 = first retry).
  ///
  /// Precedence: a server-provided [retryAfter] (429/503) is honored over the
  /// computed delay. Otherwise: `min(baseDelay * multiplier^retryIndex, maxDelay)`,
  /// then jitter. [random] returns `[0, 1)` (injectable for deterministic tests).
  Duration delayForRetry(
    int retryIndex, {
    Duration? retryAfter,
    double Function()? random,
  }) {
    if (retryAfter != null) {
      return retryAfter.isNegative ? Duration.zero : retryAfter;
    }
    final idx = retryIndex < 0 ? 0 : retryIndex;
    final grown = baseDelay.inMilliseconds * math.pow(multiplier, idx);
    final cappedMs = math.min(grown, maxDelay.inMilliseconds.toDouble());
    final ms = switch (jitter) {
      RetryJitter.none => cappedMs,
      // Full jitter: uniform in (0, capped]. random() in [0,1) → scale, then guard
      // a floor of a tiny positive so a retry never waits exactly 0 by chance.
      RetryJitter.full => cappedMs * ((random ?? _defaultRandom).call()),
    };
    return Duration(milliseconds: ms.round());
  }

  /// Parses the `upload_retry_policy` remote-config block, validating each field and
  /// falling back (per-field) to the bundled default when absent/invalid. Non-map
  /// input → all defaults. [maxRetries] is always clamped to `[0, hardMaxRetries]`.
  /// [onFallback] is invoked (once per invalid field) so the caller can log it.
  factory SessionRetryPolicy.fromConfig(
    Object? raw, {
    void Function(String field)? onFallback,
  }) {
    if (raw is! Map) return bundledDefault;

    int maxRetries = kDefaultMaxRetries;
    final rawMax = raw['maxRetries'];
    if (rawMax is num && rawMax >= 0) {
      final v = rawMax.toInt();
      if (v > hardMaxRetries) {
        maxRetries = hardMaxRetries; // clamp, not a fallback (config over-asked)
        onFallback?.call('maxRetries(clamped)');
      } else {
        maxRetries = v;
      }
    } else if (rawMax != null) {
      onFallback?.call('maxRetries');
    }

    Duration baseDelay = bundledDefault.baseDelay;
    final rawBase = raw['baseDelayMs'];
    if (rawBase is num && rawBase > 0) {
      baseDelay = Duration(milliseconds: rawBase.toInt());
    } else if (rawBase != null) {
      onFallback?.call('baseDelayMs');
    }

    double multiplier = bundledDefault.multiplier;
    final rawMult = raw['multiplier'];
    if (rawMult is num && rawMult >= 1) {
      multiplier = rawMult.toDouble();
    } else if (rawMult != null) {
      onFallback?.call('multiplier');
    }

    Duration maxDelay = bundledDefault.maxDelay;
    final rawMaxD = raw['maxDelayMs'];
    if (rawMaxD is num && rawMaxD >= baseDelay.inMilliseconds) {
      maxDelay = Duration(milliseconds: rawMaxD.toInt());
    } else if (rawMaxD != null) {
      onFallback?.call('maxDelayMs');
    }

    return SessionRetryPolicy(
      maxRetries: maxRetries,
      baseDelay: baseDelay,
      multiplier: multiplier,
      maxDelay: maxDelay,
      jitter: RetryJitter.fromWire(raw['jitter']),
    );
  }

  static double _defaultRandom() => math.Random().nextDouble();
}
