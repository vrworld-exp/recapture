// test/catalog/feedback_test.dart
//
// The feedback layer (features 67, 68, 69) — F10.
//
// Two guarantees are tested here, and only one of them is about pixels.
//
// 1. THE TABLE IS COMPLETE. `codeTable` reads the BACKEND's own sources and
//    asserts every code it can put in an error envelope has a mapped sentence
//    on this side. A new code merged into `recapture-api` with no client copy
//    fails this test — which is the point: the alternative is finding out from
//    a support call, months later, that a café owner was shown
//    `ID_SET_MISMATCH`. There is no shared package between the two codebases
//    (AGENTS.md §0.1), so hand-syncing is the contract and this is what keeps
//    it honest.
//
// 2. NO RAW UPSTREAM TEXT CAN REACH THE UI. The failure path is fed a message
//    that looks like an upstream stack trace and the rendered toast is checked
//    for any trace of it.
//
// Hermetic: the backend scan is a FILE READ inside this repo, not a request.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/catalog_error_copy.dart';
import 'package:recapture/domain/catalog/sync_error_copy.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/presentation/screens/catalog/category_manager_screen.dart';
import 'package:recapture/presentation/widgets/catalog/catalog_feedback.dart';

import 'category_manager_test.dart' as categories;

// ── The backend scan ────────────────────────────────────────────────────────

/// Where the backend lives, relative to the Flutter package root (`flutter
/// test` runs from there). Single repo, no shared package — see AGENTS.md §0.1.
const String _apiRoot = 'recapture-api/src';

/// Files that can put a `code` into a catalog response.
///
/// Listed rather than globbed on purpose: a glob over `src/` would drag in
/// project and auth codes that never reach a catalog surface, and the failure
/// message ("add copy for AUTH_OTP_EXPIRED") would send the next person to the
/// wrong table.
const List<String> _envelopeSources = [
  'routes/catalog.ts',
  'middleware/auth.ts',
  'middleware/requireRole.ts',
  'middleware/validate.ts',
  'services/catalogAnalyticsService.ts',
  'services/catalogProvisioningService.ts',
];

/// Publish's PER-ITEM codes, which reach the UI through a run's stored rows.
const String _syncSource = 'services/catalog/publishSyncErrors.ts';

/// Codes no regex can find, and why each one is here.
const Map<String, String> _alwaysRequired = {
  // errorHandler.ts's fallback for an uncaught throw: `err.code ?? 'INTERNAL_ERROR'`.
  'INTERNAL_ERROR': 'errorHandler.ts fallback',
  // CatalogFailure's own sentinels for a request that never got an envelope.
  'OFFLINE': 'CatalogFailure.fromDio, transport failure',
  'UNKNOWN': 'CatalogFailure.fromDio, non-envelope body',
  'MALFORMED_RESPONSE': 'a 2xx whose payload is missing',
};

String _readApi(String relative) {
  final file = File('$_apiRoot/$relative');
  if (!file.existsSync()) {
    fail(
      'Cannot read $_apiRoot/$relative — this test enumerates the backend\'s '
      'own error codes and cannot do its job without it. If the backend moved, '
      'update _envelopeSources; do not delete this test.',
    );
  }
  return file.readAsStringSync();
}

/// Every `UPPER_SNAKE` code the listed sources can put in an error envelope.
Set<String> _backendEnvelopeCodes() {
  final patterns = [
    // `res.json({ status:'error', code: 'X' })`
    RegExp(r"""code:\s*['"]([A-Z][A-Z0-9_]{2,})['"]"""),
    // `fail(res, 404, 'X', '...')`
    RegExp(r"""fail\(\s*res,\s*\d+,\s*['"]([A-Z][A-Z0-9_]{2,})['"]"""),
    // `export const X = 'X' as const` — codes the routes reference by name.
    RegExp(r"""export const [A-Z_]+ = ['"]([A-Z][A-Z0-9_]{2,})['"] as const"""),
  ];

  return {
    for (final source in _envelopeSources)
      for (final pattern in patterns)
        for (final match in pattern.allMatches(_readApi(source))) match.group(1)!,
  };
}

Set<String> _backendSyncCodes() => {
      for (final match
          in RegExp(r"""['"](PUBLISH_[A-Z0-9_]+)['"]""").allMatches(_readApi(_syncSource)))
        match.group(1)!,
    };

// ── Harness ─────────────────────────────────────────────────────────────────

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// Shows one toast on demand, from a screen with a real `Scaffold`.
Widget _toastHarness(void Function(ScaffoldMessengerState) show,
        {double width = 400}) =>
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: width,
          height: 800,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => show(CatalogFeedback.of(context)),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );

/// The category manager as a PUSHED route, so a test can leave it while a
/// snackbar it raised is still on screen.
Widget _pushedManagerHarness(categories.FakeCategoriesRepository repo) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        catalogProductsRepositoryProvider.overrideWithValue(
          categories.FakeCategoryProductsRepository({}),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SizedBox(
                      width: 500,
                      height: 900,
                      child: CategoryManagerScreen(),
                    ),
                  ),
                ),
                child: const Text('open manager'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('the code table covers the backend (feature 69)', () {
    test('every envelope code the API can emit has a message and an action',
        () {
      final codes = {..._backendEnvelopeCodes(), ..._alwaysRequired.keys};
      // A scan that finds nothing would pass every assertion below while
      // proving nothing — the regexes drifting is exactly the failure this
      // guards against.
      expect(codes.length, greaterThan(10),
          reason: 'the backend scan found almost nothing; the patterns in '
              '_backendEnvelopeCodes have probably gone stale');

      final unmapped = [
        for (final code in codes)
          if (catalogErrorCopyOrNull(code) == null) code,
      ]..sort();

      expect(
        unmapped,
        isEmpty,
        reason: 'These codes can reach a catalog screen with no copy of our '
            'own, so the user would be told nothing useful. Add each to '
            'lib/domain/catalog/catalog_error_copy.dart: one sentence saying '
            'what happened, one saying what to do next.',
      );
    });

    test('every per-item publish code has a message and an action', () {
      final codes = _backendSyncCodes();
      expect(codes.length, greaterThan(10));

      final unmapped = [
        for (final code in codes)
          if (catalogErrorCopyOrNull(code) == null) code,
      ]..sort();

      expect(unmapped, isEmpty,
          reason: 'Add each to lib/domain/catalog/sync_error_copy.dart.');
    });

    test('the copy reads like copy, not like a log line', () {
      final codes = {
        ..._backendEnvelopeCodes(),
        ..._alwaysRequired.keys,
        ..._backendSyncCodes(),
      };

      for (final code in codes) {
        final copy = catalogErrorCopy(code);
        final text = '${copy.message} ${copy.action ?? ''}';

        expect(copy.message, isNotEmpty, reason: code);
        expect(copy.message.endsWith('.'), isTrue,
            reason: '$code: a message is a sentence');
        // The three things a user can do nothing with.
        expect(text, isNot(contains(code)),
            reason: '$code: never show the code itself');
        expect(text, isNot(matches(RegExp(r'\b[45]\d\d\b'))),
            reason: '$code: never show an HTTP status');
        expect(text.toLowerCase(), isNot(contains('null')), reason: code);
      }
    });

    test('an unknown code degrades rather than showing itself', () {
      // A build one deploy behind the server hits this path, and it must still
      // produce a sentence — not a blank toast, not `EXPLODED_UNEXPECTEDLY`.
      const invented = 'SOMETHING_NOBODY_HAS_MAPPED';
      expect(catalogErrorCopyOrNull(invented), isNull);
      expect(catalogErrorCopy(invented), same(kCatalogUnknownError));
      expect(catalogErrorSentence(invented), isNot(contains(invented)));
      expect(catalogErrorSentence(null), isNotEmpty);
      expect(syncErrorCopy('PUBLISH_NOT_A_REAL_CODE'), same(kUnknownSyncErrorCopy));
    });

    test('offline is its own sentence, not a shade of "server error"', () {
      // Different cause, different fix: nothing the user typed was wrong and
      // nothing reached us, so "try again in a moment" would be the wrong
      // advice and "something went wrong on our side" an untrue one.
      final offline = catalogErrorCopy('OFFLINE');
      final server = catalogErrorCopy('INTERNAL_ERROR');
      expect(offline.message, isNot(server.message));
      expect(offline.message.toLowerCase(), contains('offline'));
    });
  });

  group('no raw upstream text reaches the UI (feature 69)', () {
    testWidgets('a toast shows OUR sentence, never the failure message',
        (tester) async {
      // What a proxy, a stubbed server or an upstream crash can put on the
      // wire. The backend maps this away today; the client must not depend on
      // it having done so.
      const upstream = CatalogFailure(
        code: 'NOT_FOUND',
        message: 'TypeError: cannot read property menuItem of undefined at '
            'MirageController.update (menu.js:412)',
        statusCode: 500,
      );

      await tester.pumpWidget(_toastHarness((messenger) =>
          CatalogFeedback.failure(messenger, upstream,
              subject: 'Chair 02 could not be archived')));
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.textContaining('TypeError'), findsNothing);
      expect(find.textContaining('menu.js'), findsNothing);
      expect(find.textContaining('Mirage'), findsNothing);
      expect(find.textContaining('500'), findsNothing);

      final mapped = catalogErrorCopy('NOT_FOUND');
      expect(
        find.text('Chair 02 could not be archived. ${mapped.message} '
            '${mapped.action}'),
        findsOneWidget,
      );
    });

    testWidgets('an inline banner uses the same sentence as the toast',
        (tester) async {
      const failure = CatalogFailure(code: 'DUPLICATE_NAME', message: 'nope');
      expect(
        CatalogFeedback.failureText(failure, subject: 'Chair 02'),
        catalogErrorSentence('DUPLICATE_NAME', subject: 'Chair 02'),
      );
      expect(CatalogFeedback.failureText(failure), isNot(contains('nope')));
    });
  });

  group('toast behaviour (features 67, 68)', () {
    testWidgets('two rapid actions leave one readable toast, not a pile',
        (tester) async {
      late ScaffoldMessengerState messenger;
      await tester.pumpWidget(_toastHarness((m) => messenger = m));
      await tester.tap(find.text('go'));
      await tester.pump();

      CatalogFeedback.confirm(messenger, 'Starters archived.');
      await tester.pump();
      CatalogFeedback.confirm(messenger, 'Mains archived.');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SnackBar), findsOneWidget);
      // The NEWEST one: a confirmation four seconds late reads as a report
      // about something else.
      expect(find.text('Mains archived.'), findsOneWidget);
      expect(find.text('Starters archived.'), findsNothing);

      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('the message is announced to a screen reader', (tester) async {
      // A snackbar takes no focus and is painted into the overlay, so without
      // a live region it never reaches TalkBack, VoiceOver or, on the web
      // build, `aria-live`. A confirmation nobody hears is not a confirmation.
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _toastHarness((m) => CatalogFeedback.confirm(m, 'Starters archived.')),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      final wrapper = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('Starters archived.'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(wrapper.properties.liveRegion, isTrue);

      semantics.dispose();
      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('there is a keyboard-reachable way to dismiss it',
        (tester) async {
      // Swipe is the only built-in dismissal, and there is no swipe on a
      // desktop browser. The close button is a real button in the traversal
      // order.
      await tester.pumpWidget(
        _toastHarness((m) => CatalogFeedback.confirm(m, 'Starters archived.')),
      );
      await tester.tap(find.text('go'));
      // Through the entrance animation: a snackbar sliding in is inside an
      // IgnorePointer, so a tap on it would be a tap on nothing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));

      expect(tester.widget<SnackBar>(find.byType(SnackBar)).showCloseIcon, isTrue);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a long message wraps rather than truncating', (tester) async {
      // The half that gets cut is the half that says what to do.
      await tester.pumpWidget(
        _toastHarness(
          (m) => CatalogFeedback.failure(
            m,
            const CatalogFailure(code: 'OFFLINE', message: 'x', isOffline: true),
            subject: 'A product with a genuinely long name could not be archived',
          ),
          width: 360,
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('could not be archived'),
        ),
      );
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      expect(text.maxLines, isNull);

      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('a wide window pins the toast instead of spanning it',
        (tester) async {
      // Decided from the WINDOW, never from `kIsWeb`: a 1600 px snackbar puts
      // its undo a screen's width from the card the user just acted on.
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _toastHarness((m) => CatalogFeedback.confirm(m, 'Saved.'), width: 1600),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).width,
        kCatalogToastWidth,
      );

      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });
  });

  group('undo performs the real inverse (feature 68)', () {
    testWidgets('a category reorder is offered back and written back',
        (tester) async {
      final repo = categories.FakeCategoriesRepository([
        categories.category('a', name: 'Starters', position: 0),
        categories.category('b', name: 'Mains', position: 1),
        categories.category('c', name: 'Desserts', position: 2),
      ]);

      await tester.pumpWidget(_pushedManagerHarness(repo));
      await tester.tap(find.text('open manager'));
      await tester.pumpAndSettle();

      categories.focusRow(tester, 'Mains');
      await tester.pump();
      await categories.pressAlt(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump();

      expect(repo.reorders.single, ['b', 'a', 'c']);
      expect(find.text('Undo'), findsOneWidget);

      // LEAVE the screen with the undo still on offer. This is the case the
      // whole ScaffoldMessenger-not-BuildContext design exists for: the toast
      // outlives the route that raised it.
      Navigator.of(tester.element(find.byType(CategoryManagerScreen)))
          .pop();
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.byType(CategoryManagerScreen), findsNothing);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      // The REAL inverse — a second write to the server putting the row back,
      // not a local repaint that would leave the two disagreeing.
      expect(repo.reorders.length, 2);
      expect(repo.reorders.last, ['a', 'b', 'c']);

      // And no second undo on the undo: that is a loop, not an affordance.
      expect(find.text('Undo'), findsNothing);

      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('a drag that changes nothing confirms nothing', (tester) async {
      final repo = categories.FakeCategoriesRepository([
        categories.category('a', name: 'Starters', position: 0),
        categories.category('b', name: 'Mains', position: 1),
      ]);

      await tester.pumpWidget(_pushedManagerHarness(repo));
      await tester.tap(find.text('open manager'));
      await tester.pumpAndSettle();

      // Already first: the shortcut is a no-op, and a toast here would be a
      // message about an event that did not happen.
      categories.focusRow(tester, 'Starters');
      await tester.pump();
      await categories.pressAlt(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump();

      expect(repo.reorders, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
