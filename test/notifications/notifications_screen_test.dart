// test/notifications/notifications_screen_test.dart
//
// The Notifications screen's contract. Hermetic: a fake feed repository, a
// driveable auth notifier, a fake link opener, and no router (FlowBackScope is
// applied at the ROUTER, so screen tests stay router-free).
//
// The load-bearing cases:
//   - an unread row is visibly distinct and tapping it marks it read (one
//     request, badge decremented) and opens the detail sheet when there is one;
//   - "Mark all read" is offered ONLY while something is unread;
//   - the action button opens an https link through the link seam, and an
//     in-app path never reaches it;
//   - empty and error states render, and error offers a retry that works.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/data/repositories/notifications_repository.dart';
import 'package:recapture/domain/entities/app_notification.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/presentation/screens/notifications/notifications_screen.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  NotificationsFeed feed = NotificationsFeed.empty;
  bool failFetch = false;
  int fetchCalls = 0;
  final List<String> readIds = [];
  int readAllCalls = 0;

  @override
  Future<NotificationsFeed> fetchFeed() async {
    fetchCalls++;
    if (failFetch) throw Exception('offline');
    return feed;
  }

  @override
  Future<int> markRead(String id) async {
    readIds.add(id);
    return feed.items.where((n) => !n.isRead && !readIds.contains(n.id)).length;
  }

  @override
  Future<int> markAllRead() async {
    readAllCalls++;
    return 0;
  }
}

class _FakeLinkActions implements CatalogLinkActions {
  final List<String> opened = [];

  @override
  bool get canShare => false;
  @override
  bool get canOpen => true;
  @override
  Future<void> copy(String url) async {}
  @override
  Future<void> share(String url, {String? subject}) async {}
  @override
  Future<void> open(String url) async => opened.add(url);
}

class _DrivenAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

AppNotification _n(
  String id, {
  bool read = false,
  String? detail,
  NotificationAction? action,
  NotificationKind kind = NotificationKind.info,
}) =>
    AppNotification(
      id: id,
      kind: kind,
      title: 'Title $id',
      message: 'Message $id',
      detail: detail,
      action: action,
      createdAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      isRead: read,
    );

void main() {
  late _FakeNotificationsRepository repo;
  late _FakeLinkActions links;

  Widget app() => ProviderScope(
        overrides: [
          notificationsRepositoryProvider.overrideWithValue(repo),
          catalogLinkActionsProvider.overrideWithValue(links),
          authProvider.overrideWith(_DrivenAuthNotifier.new),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const NotificationsScreen(),
        ),
      );

  setUp(() {
    repo = _FakeNotificationsRepository();
    links = _FakeLinkActions();
  });

  Finder tile(String id) => find.ancestor(
        of: find.text('Title $id'),
        matching: find.byType(NotificationTile),
      );

  TextStyle titleStyle(WidgetTester tester, String id) =>
      tester.widget<Text>(find.text('Title $id')).style!;

  testWidgets('renders the feed newest-first with unread rows emphasised',
      (tester) async {
    repo.feed = NotificationsFeed.empty.withItems([
      _n('new'),
      _n('old', read: true),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Title new'), findsOneWidget);
    expect(find.text('Title old'), findsOneWidget);
    expect(tester.getTopLeft(tile('new')).dy,
        lessThan(tester.getTopLeft(tile('old')).dy));
    expect(titleStyle(tester, 'new').fontWeight, FontWeight.w700);
    expect(titleStyle(tester, 'old').fontWeight, FontWeight.w500);
    expect(find.textContaining('ago'), findsNWidgets(2));
    // Opening the screen re-fetched once past the first watch.
    expect(repo.fetchCalls, 2);
  });

  testWidgets(
      'tapping an unread row marks it read (one request) and settles it',
      (tester) async {
    repo.feed = NotificationsFeed.empty.withItems([_n('a'), _n('b')]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(tile('a'));
    await tester.pumpAndSettle();

    expect(repo.readIds, ['a']);
    expect(titleStyle(tester, 'a').fontWeight, FontWeight.w500);
    expect(titleStyle(tester, 'b').fontWeight, FontWeight.w700);
    // No detail on this row → no sheet.
    expect(find.byIcon(Icons.close), findsNothing);

    // A second tap on the now-read row sends nothing.
    await tester.tap(tile('a'));
    await tester.pumpAndSettle();
    expect(repo.readIds, ['a']);
  });

  testWidgets('a row with a detail offers Details and opens the sheet on tap',
      (tester) async {
    repo.feed = NotificationsFeed.empty.withItems([
      _n('w', kind: NotificationKind.welcome, detail: 'The long welcome text.'),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Details'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.text('The long welcome text.'), findsOneWidget);
    expect(repo.readIds, ['w']); // opening the detail is reading it

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('The long welcome text.'), findsNothing);
  });

  testWidgets('"Mark all read" is offered only while something is unread',
      (tester) async {
    repo.feed =
        NotificationsFeed.empty.withItems([_n('a'), _n('b', read: true)]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Mark all read'), findsOneWidget);
    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();

    expect(repo.readAllCalls, 1);
    expect(find.text('Mark all read'), findsNothing);
    expect(titleStyle(tester, 'a').fontWeight, FontWeight.w500);
  });

  testWidgets(
      'an https action opens through the link seam and marks the row read',
      (tester) async {
    repo.feed = NotificationsFeed.empty.withItems([
      _n('p',
          kind: NotificationKind.paymentDue,
          action: const NotificationAction(
              label: 'Pay now', url: 'https://example.com/pay')),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Pay now'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    await tester.tap(find.text('Pay now'));
    await tester.pumpAndSettle();

    expect(links.opened, ['https://example.com/pay']);
    expect(repo.readIds, ['p']);
  });

  testWidgets('an in-app action never reaches the external opener',
      (tester) async {
    repo.feed = NotificationsFeed.empty.withItems([
      _n('a',
          action: const NotificationAction(
              label: 'Open analytics', url: '/catalog/analytics')),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    await tester.tap(find.text('Open analytics'));
    await tester.pumpAndSettle();

    expect(links.opened, isEmpty);
    expect(repo.readIds, ['a']); // still counts as reading
  });

  testWidgets('an empty feed shows the caught-up state', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up"), findsOneWidget);
    expect(find.text('Mark all read'), findsNothing);
  });

  testWidgets('a failed first load shows an error with a Retry that works',
      (tester) async {
    repo.failFetch = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load your notifications."), findsOneWidget);

    repo.failFetch = false;
    repo.feed = NotificationsFeed.empty.withItems([_n('a')]);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Title a'), findsOneWidget);
  });
}
