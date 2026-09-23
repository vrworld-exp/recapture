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

// ── The web-compiled tree ───────────────────────────────────────────────────

/// Every directory that must compile for the web target. Listed rather than
/// globbed over `lib/`, so the failure message names a directory the reader
/// recognises instead of pointing at the capture pipeline, which has its own
/// platform rules and its own gates.
///
/// THE REP DIRECTORIES ARE HERE FOR THE SAME REASON THE CATALOG ONES ARE
/// (stage 10). A rep authors from a browser as well as a phone, so every rule
/// below applies to that surface identically — and the rep tree is the one that
/// is *tempted* by `dart:io`, because it sits next to the capture flow, which
/// is native-only by nature.
const List<String> _catalogDirs = [
  'lib/application/catalog',
  'lib/domain/catalog',
  'lib/presentation/screens/catalog',
  'lib/presentation/widgets/catalog',
  'lib/application/rep',
  'lib/domain/rep',
  'lib/presentation/screens/rep',
  // THE ADMIN STANDEE SURFACE, for the third time the same reason. An admin
  // mints and sends standees from a desk at least as often as from a phone, and
  // this tree reaches for the SAME download seam the catalog QR does — so the
  // one rule that would break it (a stray `dart:io` on the delivery path) is
  // exactly the rule these guards exist to catch.
  'lib/application/admin',
  'lib/presentation/screens/admin',
];

/// Single files outside those directories that the same rules cover.
const List<String> _extraSources = [
  'lib/data/repositories/rep_repository.dart',
  'lib/data/repositories/admin_standee_repository.dart',
  'lib/domain/entities/qr_standee.dart',
  // The shared bytes-mode helpers. Both the catalog QR and every standee
  // download route their failures through this file, so a `dart:io` here would
  // take out the whole download surface on web at once.
  'lib/data/repositories/bytes_response.dart',
];

/// EVERY conditional-import seam in `lib/`, by its common prefix — the file
/// name minus `_stub.dart` / `_io.dart` / `_web.dart`.
///
/// Hand-written, because the guards below need a name to print when one is
/// broken; kept honest by `no conditional import is left off this list`, which
/// walks the tree and fails if it finds a seam this list does not know about.
const List<String> _allSeams = [
  'lib/application/catalog/qr_delivery',
  'lib/application/catalog/catalog_link_delivery',
  'lib/application/catalog/checkout_adapter',
  'lib/application/rep/rep_capabilities',
  'lib/application/rep/web_dish_camera',
  'lib/application/projects/model_export_delivery',
  'lib/application/projects/preview_download_delivery',
  'lib/platform/unsaved_changes',
  'lib/presentation/screens/projects/model_viewer_load_probe',
];

/// Every `.dart` file under `lib/`, for the tree-wide guards.
List<File> _allSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// One conditional-import seam as the source actually declares it.
class _Seam {
  const _Seam(this.prefix, this.targets);

  /// The common prefix — the stub's path minus `_stub.dart`, repo-relative.
  final String prefix;

  /// Every file the import names: the default, then each branch's target.
  /// Repo-relative, resolved against the importing file's folder.
  final List<String> targets;
}

/// A conditional import: the default library, then one or more
/// `if (dart.library.x) '…'` branches, ending at the `;`.
final RegExp _conditionalImport = RegExp(
  '[\'"]([a-zA-Z_0-9/.]+)_stub\\.dart[\'"]((?:\\s*if \\(dart\\.library\\.[a-z_]+\\)\\s*[\'"][a-zA-Z_0-9/.]+[\'"])+)',
);
final RegExp _branchTarget =
    RegExp('if \\(dart\\.library\\.[a-z_]+\\)\\s*[\'"]([a-zA-Z_0-9/.]+)[\'"]');

/// Resolves `import`'s relative target against the importing file's folder.
String _resolvedFrom(File importer, String relative) =>
    Uri.parse('${importer.parent.path.replaceAll(r'\', '/')}/')
        .resolve(relative)
        .path
        .replaceFirst(RegExp(r'^/'), '');

/// Every conditional-import seam declared across [files], deduplicated by
/// prefix (a seam re-imported by a second file is one seam).
List<_Seam> _seamsIn(List<File> files) {
  final seams = <String, _Seam>{};

  for (final file in files) {
    final source = _stripComments(file.readAsStringSync());
    for (final match in _conditionalImport.allMatches(source)) {
      final stub = _resolvedFrom(file, '${match.group(1)!}_stub.dart');
      final targets = [
        stub,
        for (final branch in _branchTarget.allMatches(match.group(2)!))
          _resolvedFrom(file, branch.group(1)!),
      ];
      seams[stub.replaceFirst('_stub.dart', '')] =
          _Seam(stub.replaceFirst('_stub.dart', ''), targets);
    }
  }
  return seams.values.toList();
}

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
      for (final path in _extraSources) File(path),
    ];

/// Source with comments removed, so a guard cannot be tripped by prose ABOUT
/// the thing it forbids. This file's own subject matter is discussed at length
/// in the catalog's comments — `catalog_qr_service.dart` explains why `kIsWeb`
/// is the right tool there and `model_picker_field.dart` explains why it is not
/// — and a naive `contains` would fail on every one of them.
String _stripComments(String source) {
  final withoutBlocks =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks.split('\n').map((line) {
    final marker = line.indexOf('//');
    if (marker == -1) return line;
    // Not a comment if the `//` is inside a string — the only case in this
    // tree is a URL, and cutting there would leave an unbalanced quote that
    // no assertion below cares about. Keeping it simple is safe here
    // because every guard searches for identifiers, not punctuation.
    return line.substring(0, marker);
  }).join('\n');
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

    test('every file a conditional import names actually exists', () {
      // A seam whose _web half is missing fails the web build outright, and
      // the conditional import turns that into a link error with no obvious
      // cause. Cheap to assert, expensive to debug.
      //
      // Asked of the IMPORT rather than of a fixed `_stub`/`_io`/`_web` triple,
      // because not every seam has all three and demanding it would be wrong:
      // `model_viewer_load_probe` is web-only by nature (mobile gets the load
      // lifecycle over a JavascriptChannel instead), so its stub IS its native
      // half and an `_io` variant would have nothing to put in it.
      final missing = <String>[];

      for (final seam in _seamsIn(_allSources())) {
        for (final target in seam.targets) {
          if (!File(target).existsSync()) missing.add(target);
        }
      }

      expect(
        missing,
        isEmpty,
        reason: 'A conditional import names a file that is not there. The '
            'default (the stub) and every `if (dart.library.…)` branch must '
            'all exist, or the target selecting the missing one will not '
            'compile.',
      );
    });

    test('every web half is selected by `dart.library.js_interop`', () {
      // THE BUG THIS EXISTS FOR, found in `preview_download_service.dart`: its
      // web half was selected with `if (dart.library.html)`, the only seam in
      // the tree that was. `dart:html` does not exist under dart2wasm, so on a
      // Wasm web build that condition is FALSE, the import falls through to
      // the STUB, and "download this photo" becomes an UnsupportedError — on
      // web only, with nothing failing anywhere else, on any other build, ever.
      // `dart.library.js_interop` is true on every web compiler.
      final offenders = [
        for (final file in _allSources())
          if (_stripComments(file.readAsStringSync())
              .contains('dart.library.html'))
            file.path,
      ];

      expect(
        offenders,
        isEmpty,
        reason: 'Select a web half with `if (dart.library.js_interop)`. '
            '`dart.library.html` is false under dart2wasm, so the seam '
            'silently resolves to its stub on a Wasm web build and the '
            'feature is missing on web with nothing to show for it.',
      );
    });

    test('no `dart:html` import survives anywhere in lib/', () {
      // The other half of the same rule. `package:web` is the supported DOM
      // binding in this SDK; `dart:html` is deprecated and absent on Wasm, so
      // a web half written against it cannot compile for the target its own
      // seam selects.
      final pattern = RegExp('import\\s+[\'"]dart:html[\'"]');
      final offenders = [
        for (final file in _allSources())
          if (pattern.hasMatch(_stripComments(file.readAsStringSync())))
            file.path,
      ];

      expect(
        offenders,
        isEmpty,
        reason: 'Use `package:web` — model_export_delivery_web.dart and '
            'preview_download_delivery_web.dart are the same anchor download '
            'written against it.',
      );
    });

    test('the seam list names every seam, and the walker finds every one', () {
      // Two failures, one test, because each covers the other's blind spot.
      //
      // `_allSeams` is hand-written and what rots is a NEW seam nobody added
      // to it — the one that then ships with a missing variant, since the
      // capability-name guard below reads the list rather than the tree.
      // And the WALKER can rot too: a regex that stopped matching would let
      // every guard above pass while checking nothing at all, which is the
      // quietest way this whole file could stop being worth running.
      final found = _seamsIn(_allSources()).map((s) => s.prefix).toSet();

      expect(
        found.difference(_allSeams.toSet()),
        isEmpty,
        reason: 'A conditional-import seam exists that `_allSeams` does not '
            'name, so nothing checks its variants or its capability flags. '
            'Add it to that list.',
      );
      expect(
        _allSeams.toSet().difference(found),
        isEmpty,
        reason: '`_allSeams` names a seam the walker did not find. Either the '
            'seam is gone (drop it from the list) or `_conditionalImport` no '
            'longer matches how these imports are written — in which case '
            'every guard in this group is silently passing over an empty set.',
      );
    });

    test('the native and web seams agree on the capability names', () {
      // The flags are compile-time constants resolved by conditional import, so
      // a name present in one variant and absent in the other is not a type
      // error anywhere — it is an undefined-identifier failure on ONE target
      // only, found by whoever builds that target next.
      const seamFlags = {
        'lib/application/catalog/catalog_link_delivery': [
          'kCanShareLink',
          'kCanOpenLink',
        ],
        'lib/application/rep/rep_capabilities': [
          'kCanScanQrCode',
          'kCanCaptureDish',
        ],
        'lib/application/catalog/checkout_adapter': ['kCanCheckoutInApp'],
      };

      for (final entry in seamFlags.entries) {
        for (final variant in ['_stub', '_io', '_web']) {
          final source = File('${entry.key}$variant.dart').readAsStringSync();

          for (final flag in entry.value) {
            expect(
              source.contains('const bool $flag'),
              isTrue,
              reason: '$flag is not declared in ${entry.key}$variant'
                  '.dart, so that target will not compile.',
            );
          }
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

    testWidgets('a build that cannot open hides Open, it does not grey it',
        (tester) async {
      // NO LONGER THE MOBILE CONFIGURATION. `kCanOpenLink` is true on both real
      // targets since url_launcher landed (matrix note B), so this drives the
      // capability directly rather than claiming to describe a platform. The
      // widget contract is what is under test and it has not changed — the stub
      // target still answers false, and a future platform may too.
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
