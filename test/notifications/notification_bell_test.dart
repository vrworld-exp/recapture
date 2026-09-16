// test/notifications/notification_bell_test.dart
//
// The Projects app-bar bell: a badge with the unread count when there is one,
// no badge at zero, "9+" past nine — and the bell itself ALWAYS present and
// tappable, whatever the feed did. Plus its place in the bar: bell, then
// Catalog, then Profile.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/notifications/notifications_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/domain/entities/app_notification.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/presentation/screens/catalog/catalog_screen.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';
import 'package:recapture/presentation/widgets/notification_bell_action.dart';

class _FakeProjectsNotifier extends ProjectsNotifier {
  @override
  Future<List<Project>> build() async => const [];

  @override
  Future<void> refresh() async {}
}

/// A feed notifier with no repository behind it: serves [initial] and makes
/// refresh a no-op so nothing reaches the network.
class _FakeNotificationsNotifier extends NotificationsNotifier {
  _FakeNotificationsNotifier(this.initial);

  final Future<NotificationsFeed> Function() initial;

  @override
  Future<NotificationsFeed> build() => initial();

  @override
  Future<void> refresh() async {}
}

NotificationsFeed _feedWithUnread(int unread) => NotificationsFeed(
      items: [
        for (var i = 0; i < unread; i++)
          AppNotification(
            id: 'n$i',
            kind: NotificationKind.info,
            title: 'T$i',
            message: 'M$i',
            createdAt: DateTime.utc(2026, 9, 1),
            isRead: false,
          ),
      ],
      unreadCount: unread,
    );

Widget _bellOnly(Future<NotificationsFeed> Function() feed) => ProviderScope(
      overrides: [
        notificationsProvider
            .overrideWith(() => _FakeNotificationsNotifier(feed)),
      ],
      child: const MaterialApp(
        home: Scaffold(appBar: _Bar()),
      ),
    );

class _Bar extends StatelessWidget implements PreferredSizeWidget {
  const _Bar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) =>
      AppBar(actions: const [NotificationBellAction()]);
}

Widget _projects(Future<NotificationsFeed> Function() feed) => ProviderScope(
      overrides: [
        projectsProvider.overrideWith(_FakeProjectsNotifier.new),
        notificationsProvider
            .overrideWith(() => _FakeNotificationsNotifier(feed)),
        isStaffProvider.overrideWithValue(false),
        isAdminProvider.overrideWithValue(false),
        avatarBytesProvider.overrideWith((ref) async => null),
      ],
      child: const MaterialApp(home: ProjectsScreen()),
    );

Finder _badgeText(String text) => find.descendant(
      of: find.byType(Badge),
      matching: find.text(text),
    );

void main() {
  group('badgeLabelFor', () {
    test('null at zero, the number through nine, 9+ beyond', () {
      expect(NotificationBellAction.badgeLabelFor(0), isNull);
      expect(NotificationBellAction.badgeLabelFor(-1), isNull);
      expect(NotificationBellAction.badgeLabelFor(1), '1');
      expect(NotificationBellAction.badgeLabelFor(9), '9');
      expect(NotificationBellAction.badgeLabelFor(10), '9+');
      expect(NotificationBellAction.badgeLabelFor(120), '9+');
    });
  });

  testWidgets('shows the unread count on the bell', (tester) async {
    await tester.pumpWidget(_bellOnly(() async => _feedWithUnread(3)));
    await tester.pumpAndSettle();

    expect(_badgeText('3'), findsOneWidget);
    expect(find.byIcon(Icons.notifications), findsOneWidget);
    expect(find.byIcon(Icons.notifications_outlined), findsNothing);
  });

  testWidgets('no badge and the outlined glyph when nothing is unread',
      (tester) async {
    await tester.pumpWidget(_bellOnly(() async => _feedWithUnread(0)));
    await tester.pumpAndSettle();

    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
  });

  testWidgets('caps at 9+', (tester) async {
    await tester.pumpWidget(_bellOnly(() async => _feedWithUnread(12)));
    await tester.pumpAndSettle();

    expect(_badgeText('9+'), findsOneWidget);
    expect(_badgeText('12'), findsNothing);
  });

  testWidgets('a failed feed fetch leaves the bell present, tappable, unbadged',
      (tester) async {
    await tester.pumpWidget(_bellOnly(() async => throw Exception('offline')));
    await tester.pumpAndSettle();

    final button =
        find.widgetWithIcon(IconButton, Icons.notifications_outlined);
    expect(button, findsOneWidget);
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
  });

  testWidgets('the bell is there while the feed is still loading',
      (tester) async {
    await tester.pumpWidget(
      _bellOnly(() => Completer<NotificationsFeed>().future),
    );
    await tester.pump();

    expect(find.byType(NotificationBellAction), findsOneWidget);
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
  });

  testWidgets(
      'on the Projects hub it sits BEFORE Catalog, which is before Profile',
      (tester) async {
    await tester.pumpWidget(_projects(() async => _feedWithUnread(2)));
    await tester.pumpAndSettle();

    final bar = find.byType(AppBar);
    final bell =
        find.descendant(of: bar, matching: find.byType(NotificationBellAction));
    final catalog =
        find.descendant(of: bar, matching: find.byType(CatalogEntryAction));
    final profile = find.descendant(
      of: bar,
      matching: find.widgetWithIcon(IconButton, Icons.account_circle_outlined),
    );
    expect(bell, findsOneWidget);
    expect(catalog, findsOneWidget);
    expect(profile, findsOneWidget);

    final bellX = tester.getCenter(bell).dx;
    final catalogX = tester.getCenter(catalog).dx;
    final profileX = tester.getCenter(profile).dx;
    expect(bellX, lessThan(catalogX));
    expect(catalogX, lessThan(profileX));

    // And the badge made it onto the hub.
    expect(_badgeText('2'), findsOneWidget);
  });
}
