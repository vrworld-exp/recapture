// test/admin/admin_all_catalogs_test.dart
//
// The ADMIN's "All catalogs": who reaches it, what a card is made of, how the
// grid behaves at its edges (empty, no match, failure, paging), and the one
// change to the shared preview page — a banner that opens the editor ONLY when
// asked to.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/data/repositories/admin_catalogs_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/domain/catalog/catalog_preview.dart';
import 'package:recapture/domain/entities/admin_catalog_card.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_status.dart';
import 'package:recapture/domain/entities/user_role.dart';
import 'package:recapture/presentation/screens/admin/admin_catalogs_screen.dart';
import 'package:recapture/presentation/widgets/catalog/catalog_preview_page.dart';

// ── Fakes ───────────────────────────────────────────────────────────────────

class _FakeRepo implements AdminCatalogsRepository {
  _FakeRepo(this.pages);

  /// Pages served in order for the empty query; a query gets [byQuery].
  final List<AdminCatalogPage> pages;
  final Map<String, AdminCatalogPage> byQuery = {};
  final List<({String? query, String? cursor})> calls = [];
  bool fail = false;

  @override
  Future<AdminCatalogPage> list({String? query, String? cursor}) async {
    calls.add((query: query, cursor: cursor));
    if (fail) {
      throw const CatalogFailure(code: 'NETWORK', message: 'offline');
    }
    final q = query ?? '';
    if (q.isNotEmpty) {
      return byQuery[q] ?? const AdminCatalogPage(items: [], nextCursor: null);
    }
    final index = cursor == null ? 0 : int.parse(cursor);
    return pages[index];
  }
}

AdminCatalogCard _card(String id, String name, {bool draft = false}) =>
    AdminCatalogCard(id: id, name: name, hasDraftChanges: draft);

Widget _harness(_FakeRepo repo) => ProviderScope(
      overrides: [adminCatalogsRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: AdminCatalogsScreen()),
    );

void main() {
  // ── The gate ──────────────────────────────────────────────────────────────

  group('the router gate', () {
    String? redirect(UserRole role, String location) =>
        adminStandeesRedirectFor(location, canUseStandees: role.isAdmin);

    const locations = [
      AppRoutes.adminCatalogs,
      '/admin/catalogs/6a9acad224584032c410c5c8',
    ];

    test('lets an ADMIN through the grid and a catalog page', () {
      for (final location in locations) {
        expect(redirect(UserRole.admin, location), isNull, reason: location);
      }
    });

    test('sends every lesser role to its own hub — a rep included', () {
      for (final role in [
        UserRole.user,
        UserRole.salesRep,
        UserRole.modelArtist,
      ]) {
        for (final location in locations) {
          expect(redirect(role, location), AppRoutes.projects,
              reason: '$role at $location');
        }
      }
    });

    test('is a prefix, not a lookalike', () {
      expect(redirect(UserRole.user, '/admin/catalogsx'), isNull);
    });
  });

  // ── The card ──────────────────────────────────────────────────────────────

  group('AdminCatalogCard.fromMap', () {
    test('reads the wire shape and de-slugs the name for display', () {
      final card = AdminCatalogCard.fromMap({
        'id': 'c1',
        'name': 'blue_cafe',
        'businessName': 'Blue Hospitality',
        'logoUrl': 'https://cdn.test/logo.jpg',
        'publicUrl': 'https://menu.test/blue_cafe',
        'isBranch': true,
        'hasDraftChanges': true,
        'lastPublishedAt': '2026-09-30T10:00:00.000Z',
      })!;
      expect(card.displayName, 'blue cafe');
      expect(card.isBranch, isTrue);
      expect(card.hasDraftChanges, isTrue);
      expect(card.lastPublishedAt, DateTime.utc(2026, 9, 30, 10));
    });

    test('drops a row with no id, and blanks become null', () {
      expect(AdminCatalogCard.fromMap({'name': 'x'}), isNull);
      final card = AdminCatalogCard.fromMap(
          {'id': 'c1', 'name': 'x', 'logoUrl': '  ', 'isBranch': 'yes'})!;
      expect(card.logoUrl, isNull);
      expect(card.isBranch, isFalse);
      expect(card.lastPublishedAt, isNull);
    });
  });

  // ── The grid ──────────────────────────────────────────────────────────────

  group('AdminCatalogsScreen', () {
    // A tall phone: the grid builds lazily, so a second row has to be on
    // screen to exist at all.
    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(400, 2400);
      view.devicePixelRatio = 1;
    });
    tearDown(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    testWidgets('lays the catalogs out two to a row', (tester) async {
      final repo = _FakeRepo([
        AdminCatalogPage(items: [
          _card('a', 'a_cafe'),
          _card('b', 'b_cafe', draft: true),
          _card('c', 'c_cafe'),
        ], nextCursor: null),
      ]);
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      final a =
          tester.getTopLeft(find.byKey(const ValueKey('admin_catalog_card_a')));
      final b =
          tester.getTopLeft(find.byKey(const ValueKey('admin_catalog_card_b')));
      final c =
          tester.getTopLeft(find.byKey(const ValueKey('admin_catalog_card_c')));
      expect(a.dy, b.dy, reason: 'first two share a row');
      expect(b.dx, greaterThan(a.dx));
      expect(c.dy, greaterThan(a.dy), reason: 'the third starts row two');
      expect(c.dx, a.dx);

      // Names are de-slugged; a logo-less card shows its initial, not a blank.
      expect(find.text('a cafe'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('Unpublished edits'), findsOneWidget);
    });

    testWidgets('shows each catalog as Live, Offline or Updating',
        (tester) async {
      final repo = _FakeRepo([
        const AdminCatalogPage(items: [
          AdminCatalogCard(id: 'a', name: 'a_cafe'),
          AdminCatalogCard(id: 'b', name: 'b_cafe', isLive: false),
          AdminCatalogCard(id: 'c', name: 'c_cafe', isPublishing: true),
        ], nextCursor: null),
      ]);
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      String chip(String id) =>
          (tester
              .widget<Text>(find.descendant(
                of: find.byKey(ValueKey('admin_catalog_status_$id')),
                matching: find.byType(Text),
              ))
              .data) ??
          '';
      expect(chip('a'), 'Live');
      expect(chip('b'), 'Offline');
      expect(chip('c'), 'Updating…');
    });

    test('reads the status off the wire, defaulting to live', () {
      expect(
          AdminCatalogCard.fromMap({'id': 'x', 'status': 'UNPUBLISHED'})!
              .isLive,
          isFalse);
      expect(
          AdminCatalogCard.fromMap({'id': 'x', 'status': 'PUBLISHED'})!.isLive,
          isTrue);
      expect(AdminCatalogCard.fromMap({'id': 'x'})!.isLive, isTrue);
      expect(
          AdminCatalogCard.fromMap({'id': 'x', 'isPublishing': true})!
              .isPublishing,
          isTrue);
    });

    testWidgets('says so when nothing is live yet', (tester) async {
      final repo =
          _FakeRepo([const AdminCatalogPage(items: [], nextCursor: null)]);
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      expect(find.text('No live catalogs yet.'), findsOneWidget);
    });

    testWidgets('a search with no match offers to clear it', (tester) async {
      final repo = _FakeRepo([
        AdminCatalogPage(items: [_card('a', 'a_cafe')], nextCursor: null),
      ]);
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('admin_catalogs_search')), 'zzz');
      await tester.pump(const Duration(milliseconds: 400)); // debounce
      await tester.pumpAndSettle();
      expect(find.text('No catalog matches "zzz".'), findsOneWidget);
      expect(repo.calls.last.query, 'zzz');

      await tester.tap(find.text('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('a cafe'), findsOneWidget);
    });

    testWidgets('a failed load is one sentence and a retry', (tester) async {
      final repo = _FakeRepo([
        AdminCatalogPage(items: [_card('a', 'a_cafe')], nextCursor: null),
      ])
        ..fail = true;
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load catalogs."), findsOneWidget);
      expect(find.textContaining('offline'), findsNothing);

      repo.fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('a cafe'), findsOneWidget);
    });

    testWidgets('loads the next page, without showing a card twice',
        (tester) async {
      final repo = _FakeRepo([
        AdminCatalogPage(
            items: [_card('a', 'a_cafe'), _card('b', 'b_cafe')],
            nextCursor: '1'),
        // `b` again: a rename between pages can move a row past the cursor.
        AdminCatalogPage(
            items: [_card('b', 'b_cafe'), _card('c', 'c_cafe')],
            nextCursor: null),
      ]);
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      // The short first page never scrolls, so the button is the way on.
      final more = find.text('Load more');
      if (more.evaluate().isNotEmpty) {
        await tester.ensureVisible(more);
        await tester.tap(more);
      }
      await tester.pumpAndSettle();

      expect(find.text('c cafe'), findsOneWidget);
      expect(find.text('b cafe'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });
  });

  // ── The banner ────────────────────────────────────────────────────────────

  group('CatalogPreviewPage banner', () {
    CatalogPreview preview() => CatalogPreview(
          catalog: const Catalog(
            id: 'c1',
            name: 'blue_cafe',
            status: CatalogStatus.published,
            hasUnpublishedChanges: false,
            isPublishing: false,
            isProvisioned: true,
          ),
          profile: null,
          sections: const [],
          products: const [],
          gates: const [],
        );

    Widget page({VoidCallback? onHeaderTap}) => MaterialApp(
          home: Scaffold(
            body: CatalogPreviewPage(
              preview: preview(),
              noticeBody: 'notice',
              onHeaderTap: onHeaderTap,
            ),
          ),
        );

    testWidgets('opens the editor when the admin taps it', (tester) async {
      var taps = 0;
      await tester.pumpWidget(page(onHeaderTap: () => taps++));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preview_header_edit')));
      expect(taps, 1);
    });

    testWidgets('stays exactly the customer view everywhere else',
        (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preview_header_edit')), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('blue cafe'), findsOneWidget);
    });
  });
}
