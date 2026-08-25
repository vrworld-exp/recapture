// test/catalog/web_parity_test.dart
//
// F11 — the web parity gates, and the guards that keep them.
//
// Two kinds of test live here, and they fail for different reasons.
//
// 1. BEHAVIOURAL. The capability flags are driven through their provider, so
//    one widget test asserts BOTH platforms' rendering without running on
//    either. This is the whole argument for `CatalogLinkActions` over a
//    `kIsWeb` branch: a branch on a compile-time constant cannot be tested at
//    all — the untaken half is not even compiled into the test binary — so the
//    mobile rendering would be unverifiable from a `flutter test` run, which is
//    the only run CI does.
//
// 2. STRUCTURAL. Source-level guards over the catalog tree: no `dart:io` on a
//    path the web build compiles, no `kIsWeb` deciding layout, and every
//    conditional-import seam complete in all three variants. These catch the
//    failure mode that has no runtime symptom on the platform you are testing —
//    a `dart:io` import that analyzes and tests perfectly on the VM and only
//    fails when someone runs `flutter build web`, months later.
//
// Hermetic: the structural half is a FILE READ inside this repo, and the
// behavioural half overrides every seam. No network, no platform channels.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/presentation/widgets/catalog/publish_link_actions.dart';

import 'publish_fakes.dart';

// ── The catalog tree ────────────────────────────────────────────────────────

/// Every directory that is "the catalog surface" for the purposes of these
/// guards. Listed rather than globbed over `lib/`, so the failure message names
/// a directory the reader recognises instead of pointing at the capture
/// pipeline, which has its own platform rules and its own gates.
const List<String> _catalogDirs = [
  'lib/application/catalog',
  'lib/domain/catalog',
  'lib/presentation/screens/catalog',
  'lib/presentation/widgets/catalog',
];

/// Files allowed to import `dart:io`: the native half of a conditional-import
/// seam. These are selected by `if (dart.library.io)` and are never compiled
/// into a web build, which is precisely what makes them safe — and what makes
/// every OTHER `dart:io` in the tree a web build failure.
bool _isNativeSeam(String path) => path.endsWith('_io.dart');

List<File> _catalogSources() => [
      for (final dir in _catalogDirs)
        ...Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];

/// Source with comments removed, so a guard cannot be tripped by prose ABOUT
/// the thing it forbids. This file's own subject matter is discussed at length
/// in the catalog's comments — `catalog_qr_service.dart` explains why `kIsWeb`
/// is the right tool there and `model_picker_field.dart` explains why it is not
/// — and a naive `contains` would fail on every one of them.
String _stripComments(String source) {
  final withoutBlocks = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks
      .split('\n')
      .map((line) {
        final marker = line.indexOf('//');
        if (marker == -1) return line;
        // Not a comment if the `//` is inside a string — the only case in this
        // tree is a URL, and cutting there would leave an unbalanced quote that
        // no assertion below cares about. Keeping it simple is safe here
        // because every guard searches for identifiers, not punctuation.
        return line.substring(0, marker);
      })
      .join('\n');
}

void main() {
  // ── Structural guards ─────────────────────────────────────────────────────

  group('the catalog surface compiles for the web target', () {
    test('no `dart:io` import outside a conditional-import native seam', () {
      final offenders = <String>[];

      for (final file in _catalogSources()) {
        if (_isNativeSeam(file.path)) continue;
        final source = _stripComments(file.readAsStringSync());
        if (RegExp(r"""import\s+['"]dart:io['"]""").hasMatch(source)) {
          offenders.add(file.path);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: '`dart:io` is unavailable on the web target, so these files '
            'break `flutter build web` while analyzing and testing perfectly '
            'on the VM. If the import is a genuine platform capability, split '
            'it behind a conditional import (see qr_delivery_io.dart / '
            '_web.dart / _stub.dart) rather than importing it directly.',
      );
    });

    test('the guard can actually see the tree it is guarding', () {
      // A listing that found nothing would pass every assertion in this group
      // while proving nothing — the directories being renamed out from under
      // these guards is exactly the silent failure they exist to prevent.
      expect(_catalogSources().length, greaterThan(20));
    });

    test('no `kIsWeb` decides anything in catalog code', () {
      final offenders = <String>[];

      for (final file in _catalogSources()) {
        final source = _stripComments(file.readAsStringSync());
        if (source.contains('kIsWeb')) offenders.add(file.path);
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Layout comes from BoxConstraints — a narrow browser window is '
            'a phone layout, not a squeezed desktop one. And a genuine '
            'CAPABILITY split belongs behind a conditional import with a '
            'provider-exposed flag, so a widget test can drive both platforms '
            '(as this file does). A `kIsWeb` branch is untestable: the untaken '
            'half is not compiled into the test binary at all.',
      );
    });

    test('every platform seam ships all three variants', () {
      // A seam missing its stub still compiles on both real targets and fails
      // only on a third — but a seam missing its _web half fails the web build
      // outright, and the conditional import makes that a link error with no
      // obvious cause. Cheap to assert, expensive to debug.
      const seams = [
        'lib/application/catalog/qr_delivery',
        'lib/application/catalog/catalog_link_delivery',
      ];

      for (final seam in seams) {
        for (final variant in ['_stub.dart', '_io.dart', '_web.dart']) {
          expect(
            File('$seam$variant').existsSync(),
            isTrue,
            reason: '$seam$variant is missing. A conditional import needs all '
                'three: the stub is the default, and the other two are '
                'selected by dart.library.io / dart.library.js_interop.',
          );
        }
      }
    });

    test('the native and web seams agree on the capability names', () {
      // The flags are compile-time constants resolved by conditional import, so
      // a name present in one variant and absent in the other is not a type
      // error anywhere — it is an undefined-identifier failure on ONE target
      // only, found by whoever builds that target next.
      const flags = ['kCanShareLink', 'kCanOpenLink'];

      for (final variant in ['_stub', '_io', '_web']) {
        final source = File(
          'lib/application/catalog/catalog_link_delivery$variant.dart',
        ).readAsStringSync();

        for (final flag in flags) {
          expect(
            source.contains('const bool $flag'),
            isTrue,
            reason: '$flag is not declared in catalog_link_delivery$variant '
                '.dart, so that target will not compile.',
          );
        }
      }
    });
  });

  // ── Behavioural gates ─────────────────────────────────────────────────────

  group('link actions render what the platform can actually do', () {
    Widget harness(CatalogLinkActions actions) => ProviderScope(
          overrides: [
            catalogLinkActionsProvider.overrideWithValue(actions),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: PublishLinkActions(url: 'https://mirage.example/c/cafe'),
            ),
          ),
        );

    testWidgets('a mobile build offers Share and hides Open', (tester) async {
      await tester.pumpWidget(
        harness(FakeLinkActions(canShare: true, canOpen: false)),
      );

      expect(find.byKey(const ValueKey('link_copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('link_share')), findsOneWidget);
      // HIDDEN, not disabled. A greyed button asks the user to wonder what they
      // did wrong; an absent one is simply not part of this platform.
      expect(find.byKey(const ValueKey('link_open')), findsNothing);
    });

    testWidgets('a web build offers Open and hides Share', (tester) async {
      await tester.pumpWidget(
        harness(FakeLinkActions(canShare: false, canOpen: true)),
      );

      expect(find.byKey(const ValueKey('link_copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('link_share')), findsNothing);
      expect(find.byKey(const ValueKey('link_open')), findsOneWidget);
    });

    testWidgets('a platform with neither still offers Copy', (tester) async {
      // The stub's own answer: both flags false. Copy is the floor, because it
      // is the one action with no platform story at all — Flutter's Clipboard
      // handles the secure-context fallback inside the engine.
      await tester.pumpWidget(
        harness(FakeLinkActions(canShare: false, canOpen: false)),
      );

      expect(find.byKey(const ValueKey('link_copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('link_share')), findsNothing);
      expect(find.byKey(const ValueKey('link_open')), findsNothing);
    });

    testWidgets('copy sends the URL VERBATIM and says it worked',
        (tester) async {
      final actions = FakeLinkActions(canShare: true, canOpen: false);
      await tester.pumpWidget(harness(actions));

      await tester.tap(find.byKey(const ValueKey('link_copy')));
      await tester.pump();
      await tester.pump();

      // Verbatim: every printed QR resolves through this string, so a client
      // that normalised it would break stickers already on tables.
      expect(actions.copied, ['https://mirage.example/c/cafe']);
      expect(find.text('Link copied.'), findsOneWidget);
    });

    testWidgets('a refused clipboard is a sentence, not a silent no-op',
        (tester) async {
      // The web failure this models: a clipboard write refused in an insecure
      // context or without a user gesture the browser recognised. It arrives as
      // a platform exception whose text is not for a user.
      final actions = FakeLinkActions(canShare: false, canOpen: true)
        ..failure = StateError('NotAllowedError: write permission denied');
      await tester.pumpWidget(harness(actions));

      await tester.tap(find.byKey(const ValueKey('link_copy')));
      await tester.pump();
      await tester.pump();

      expect(actions.copied, isEmpty);
      expect(
        find.textContaining('copy it by hand'),
        findsOneWidget,
        reason: 'a button that silently may or may not have worked is worse '
            'than one that says which',
      );
      // No raw upstream text (F10's rule, and a platform exception is exactly
      // the kind of prose it exists to keep off the screen).
      expect(find.textContaining('NotAllowedError'), findsNothing);
    });
  });
}
