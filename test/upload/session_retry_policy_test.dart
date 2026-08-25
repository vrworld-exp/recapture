// test/upload/session_retry_policy_test.dart
//
// Pure tests for the session retry policy: config parse/validate/clamp + backoff.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/session_retry_policy.dart';

void main() {
  group('fromConfig', () {
    test('non-map → all defaults', () {
      const p = SessionRetryPolicy.bundledDefault;
      final parsed = SessionRetryPolicy.fromConfig(null);
      expect(parsed.maxRetries, p.maxRetries);
      expect(parsed.baseDelay, p.baseDelay);
      expect(parsed.multiplier, p.multiplier);
      expect(parsed.maxDelay, p.maxDelay);
    });

    test('valid config is honored', () {
      final p = SessionRetryPolicy.fromConfig({
        'maxRetries': 2,
        'baseDelayMs': 500,
        'multiplier': 3.0,
        'maxDelayMs': 10000,
        'jitter': 'none',
      });
      expect(p.maxRetries, 2);
      expect(p.baseDelay, const Duration(milliseconds: 500));
      expect(p.multiplier, 3.0);
      expect(p.maxDelay, const Duration(milliseconds: 10000));
      expect(p.jitter, RetryJitter.none);
    });

    test('maxRetries above the hard cap is clamped (not a larger value)', () {
      final fallbacks = <String>[];
      final p = SessionRetryPolicy.fromConfig(
        {'maxRetries': 100},
        onFallback: fallbacks.add,
      );
      expect(p.maxRetries, SessionRetryPolicy.hardMaxRetries); // 3
      expect(fallbacks, contains('maxRetries(clamped)'));
    });

    test('invalid values fall back to defaults and log', () {
      final fallbacks = <String>[];
      final p = SessionRetryPolicy.fromConfig(
        {'maxRetries': -1, 'baseDelayMs': 0, 'multiplier': 0.5},
        onFallback: fallbacks.add,
      );
      expect(p.maxRetries, SessionRetryPolicy.kDefaultMaxRetries);
      expect(p.baseDelay, SessionRetryPolicy.bundledDefault.baseDelay);
      expect(p.multiplier, SessionRetryPolicy.bundledDefault.multiplier);
      expect(fallbacks, containsAll(['maxRetries', 'baseDelayMs', 'multiplier']));
    });

    test('maxAttempts is retries + 1', () {
      expect(const SessionRetryPolicy(maxRetries: 3).maxAttempts, 4);
      expect(const SessionRetryPolicy(maxRetries: 0).maxAttempts, 1);
    });
  });

  group('delayForRetry', () {
    const p = SessionRetryPolicy(
      baseDelay: Duration(seconds: 1),
      multiplier: 2.0,
      maxDelay: Duration(seconds: 30),
      jitter: RetryJitter.full,
    );

    test('exponential growth with full jitter at random()=1.0 → exact schedule', () {
      double one() => 1.0;
      expect(p.delayForRetry(0, random: one), const Duration(milliseconds: 1000));
      expect(p.delayForRetry(1, random: one), const Duration(milliseconds: 2000));
      expect(p.delayForRetry(2, random: one), const Duration(milliseconds: 4000));
    });

    test('capped at maxDelay', () {
      const capped = SessionRetryPolicy(
        baseDelay: Duration(seconds: 1),
        multiplier: 2.0,
        maxDelay: Duration(seconds: 3),
        jitter: RetryJitter.full,
      );
      double one() => 1.0;
      expect(capped.delayForRetry(10, random: one), const Duration(seconds: 3));
    });

    test('full jitter scales by random()', () {
      double half() => 0.5;
      expect(p.delayForRetry(1, random: half), const Duration(milliseconds: 1000));
    });

    test('no-jitter returns the exact computed delay', () {
      const none = SessionRetryPolicy(
        baseDelay: Duration(seconds: 1),
        multiplier: 2.0,
        jitter: RetryJitter.none,
      );
      expect(none.delayForRetry(2), const Duration(milliseconds: 4000));
    });

    test('Retry-After overrides the computed backoff', () {
      double one() => 1.0;
      expect(
        p.delayForRetry(0, retryAfter: const Duration(seconds: 7), random: one),
        const Duration(seconds: 7),
      );
    });
  });
}
