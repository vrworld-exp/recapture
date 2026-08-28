// test/capture/capture_level_session_test.dart
//
// Coverage for the capture-level analytics session: start mints an opaque id +
// timestamp, ensure reuses a same-level session (retake linkage) but starts fresh
// across levels, duration is non-negative, and the completion claim latches to
// once per session (resetting on a new start).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';

void main() {
  late ProviderContainer container;
  CaptureLevelSessionNotifier notifier() =>
      container.read(captureLevelSessionProvider.notifier);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('start mints an opaque session id + records the start time', () {
    final t = DateTime(2026, 6, 23, 10);
    final s = notifier().start(level: CaptureLevel.a, projectId: 'p', now: t);
    expect(s.sessionId, isNotEmpty);
    expect(s.startedAt, t);
    expect(s.level, CaptureLevel.a);
    expect(container.read(captureLevelSessionProvider), s);
  });

  test('a fresh start mints a different id', () {
    final a = notifier().start(level: CaptureLevel.a, projectId: 'p');
    final b = notifier().start(level: CaptureLevel.a, projectId: 'p');
    expect(a.sessionId, isNot(b.sessionId));
  });

  test('ensure reuses a same-level session (retake linkage)', () {
    final started = notifier().start(level: CaptureLevel.a, projectId: 'p');
    final ensured = notifier().ensure(level: CaptureLevel.a, projectId: 'p');
    expect(ensured.sessionId, started.sessionId);
  });

  test('ensure starts fresh when the level differs', () {
    final a = notifier().start(level: CaptureLevel.a, projectId: 'p');
    final b = notifier().ensure(level: CaptureLevel.b, projectId: 'p');
    expect(b.level, CaptureLevel.b);
    expect(b.sessionId, isNot(a.sessionId));
  });

  test('duration is whole seconds, clamped non-negative', () {
    final start = DateTime(2026, 6, 23, 10, 0, 0);
    final s = notifier().start(level: CaptureLevel.a, projectId: 'p', now: start);
    expect(s.durationSecondsUntil(start.add(const Duration(seconds: 90))), 90);
    expect(s.durationSecondsUntil(start.subtract(const Duration(seconds: 5))), 0);
  });

  group('completion claim (latch)', () {
    test('first claim emits with the session; second does not', () {
      final s = notifier().start(level: CaptureLevel.a, projectId: 'p');

      final first = notifier().claimCompletion();
      expect(first.shouldEmit, isTrue);
      expect(first.session?.sessionId, s.sessionId);

      final second = notifier().claimCompletion();
      expect(second.shouldEmit, isFalse);
    });

    test('a new start resets the latch (a new session can complete)', () {
      notifier().start(level: CaptureLevel.a, projectId: 'p');
      notifier().claimCompletion();

      notifier().start(level: CaptureLevel.a, projectId: 'p');
      expect(notifier().claimCompletion().shouldEmit, isTrue);
    });

    test('claiming with no session still emits once (unlinked)', () {
      final claim = notifier().claimCompletion();
      expect(claim.shouldEmit, isTrue);
      expect(claim.session, isNull);
      expect(notifier().claimCompletion().shouldEmit, isFalse);
    });
  });
}
