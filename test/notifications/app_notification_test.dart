// test/notifications/app_notification_test.dart
//
// The feed parser's contract: defensive on every field beyond the shape
// itself, the read flag derivable from either `isRead` or a `readAt`, and the
// count re-derived after a local read flip.
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/domain/entities/app_notification.dart';

Map<String, dynamic> _row({
  String id = 'n1',
  String kind = 'INFO',
  String title = 'Title',
  String message = 'Body',
  Object? detail,
  Object? action,
  Object? createdAt = '2026-09-10T10:00:00.000Z',
  Object? isRead = false,
  Object? readAt,
}) =>
    {
      'id': id,
      'kind': kind,
      'title': title,
      'message': message,
      'detail': detail,
      'action': action,
      'createdAt': createdAt,
      'isRead': isRead,
      'readAt': readAt,
    };

void main() {
  group('AppNotification.tryFromJson', () {
    test('parses a full row', () {
      final n = AppNotification.tryFromJson(_row(
        kind: 'PAYMENT_DUE',
        detail: 'Long text',
        action: {'label': 'Pay now', 'url': 'https://example.com/pay'},
      ))!;

      expect(n.id, 'n1');
      expect(n.kind, NotificationKind.paymentDue);
      expect(n.title, 'Title');
      expect(n.message, 'Body');
      expect(n.detail, 'Long text');
      expect(n.hasDetail, isTrue);
      expect(
          n.action,
          const NotificationAction(
              label: 'Pay now', url: 'https://example.com/pay'));
      expect(n.action!.isInAppRoute, isFalse);
      expect(n.createdAt, DateTime.utc(2026, 9, 10, 10));
      expect(n.isRead, isFalse);
      expect(n.readAt, isNull);
    });

    test('an in-app action url is recognised by its leading slash', () {
      final n = AppNotification.tryFromJson(_row(
        action: {'label': 'Open', 'url': '/catalog/analytics'},
      ))!;
      expect(n.action!.isInAppRoute, isTrue);
    });

    test('drops a row missing id/title/message — the shape itself', () {
      expect(AppNotification.tryFromJson(_row(id: '')), isNull);
      expect(AppNotification.tryFromJson({'id': 'x', 'title': 'T'}), isNull);
      expect(AppNotification.tryFromJson('nope'), isNull);
    });

    test('degrades every other field rather than throwing', () {
      final n = AppNotification.tryFromJson(_row(
        kind: 'SOMETHING_NEW',
        detail: '   ',
        action: {'label': 'no url'},
        createdAt: 'not a date',
        isRead: 'yes',
      ))!;
      expect(n.kind, NotificationKind.info);
      expect(n.hasDetail, isFalse);
      expect(n.action, isNull);
      expect(n.createdAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect(n.isRead, isFalse);
    });

    test('a readAt alone means read (an older backend without the flag)', () {
      final n = AppNotification.tryFromJson(
        _row(isRead: null, readAt: '2026-09-11T00:00:00Z'),
      )!;
      expect(n.isRead, isTrue);
      expect(n.readAt, DateTime.utc(2026, 9, 11));
    });

    test('markedRead flips once and is a no-op on a read row', () {
      final n = AppNotification.tryFromJson(_row())!;
      final read = n.markedRead(at: DateTime.utc(2026, 9, 12));
      expect(read.isRead, isTrue);
      expect(read.readAt, DateTime.utc(2026, 9, 12));
      expect(identical(read.markedRead(), read), isTrue);
    });
  });

  group('NotificationsFeed.fromJson', () {
    test('keeps order, skips malformed rows, and carries the server count', () {
      final feed = NotificationsFeed.fromJson({
        'notifications': [
          _row(id: 'a'),
          {'garbage': true},
          _row(id: 'b', isRead: true),
        ],
        'unreadCount': 7, // deliberately not what the rows say
      });
      expect(feed.items.map((n) => n.id), ['a', 'b']);
      expect(feed.unreadCount, 7);
      expect(feed.hasUnread, isTrue);
    });

    test('derives the count when the server omits it', () {
      final feed = NotificationsFeed.fromJson({
        'notifications': [_row(id: 'a'), _row(id: 'b', isRead: true)],
      });
      expect(feed.unreadCount, 1);
    });

    test('a missing list is an empty feed, not an error', () {
      final feed = NotificationsFeed.fromJson({'unreadCount': 0});
      expect(feed.isEmpty, isTrue);
      expect(feed.hasUnread, isFalse);
    });

    test('withItems re-derives the count from the rows', () {
      final feed = NotificationsFeed.fromJson({
        'notifications': [_row(id: 'a'), _row(id: 'b')],
        'unreadCount': 2,
      });
      final next = feed.withItems([feed.items[0].markedRead(), feed.items[1]]);
      expect(next.unreadCount, 1);
    });
  });
}
