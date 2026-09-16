// lib/domain/entities/app_notification.dart
//
// One in-app notification as `GET /notifications` ships it, and the feed that
// wraps the list. Hand-synced with `recapture-api/src/services/
// notificationsService.ts` (NotificationDto / NotificationFeedDto) — there is
// no shared package, per AGENTS.md.
//
// Named AppNotification, not Notification: Flutter's own `Notification` class
// (the widget-tree bubbling one) is imported wherever `material.dart` is.
//
// Nothing here is PII, but a message CAN be addressed to one person about
// their own account ("your payment is overdue"), so the title/body are never
// logged or sent to analytics — only the id and the kind.

/// What a notification is about. Drives the icon and nothing else.
enum NotificationKind {
  welcome,
  info,
  paymentDue,
  paymentActivate,
  analytics,
  system;

  /// Wire → enum. Unknown values degrade to [info] rather than throwing, so a
  /// kind the server adds tomorrow renders as a plain message today.
  static NotificationKind fromApiValue(String? value) => switch (value) {
        'WELCOME' => NotificationKind.welcome,
        'PAYMENT_DUE' => NotificationKind.paymentDue,
        'PAYMENT_ACTIVATE' => NotificationKind.paymentActivate,
        'ANALYTICS' => NotificationKind.analytics,
        'SYSTEM' => NotificationKind.system,
        _ => NotificationKind.info,
      };
}

/// The optional call-to-action on a notification.
class NotificationAction {
  const NotificationAction({required this.label, required this.url});

  final String label;

  /// Either an in-app route (`/catalog/analytics`) or an absolute https link.
  final String url;

  /// The server accepts exactly two shapes — a path the app's router owns, or
  /// an https link — and the leading `/` is the discriminator on both sides.
  bool get isInAppRoute => url.startsWith('/');

  /// Defensive parse: a malformed action (missing label or url) is null — the
  /// notification still renders, just without its button.
  static NotificationAction? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final url = json['url'];
    if (label is! String || label.trim().isEmpty) return null;
    if (url is! String || url.trim().isEmpty) return null;
    return NotificationAction(label: label.trim(), url: url.trim());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationAction && other.label == label && other.url == url;

  @override
  int get hashCode => Object.hash(label, url);
}

/// Immutable notification row.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.isRead,
    this.detail,
    this.action,
    this.readAt,
  });

  final String id;
  final NotificationKind kind;
  final String title;

  /// The body shown in the list row.
  final String message;

  /// Long-form text behind the "Details" button, or null for none.
  final String? detail;

  /// The CTA, or null for none.
  final NotificationAction? action;

  /// When the admin sent it, in UTC.
  final DateTime createdAt;

  /// Whether THIS user has opened it. Server-derived from their receipt.
  final bool isRead;

  /// The first time this user opened it, or null while unread.
  final DateTime? readAt;

  bool get hasDetail => detail?.trim().isNotEmpty ?? false;
  bool get hasAction => action != null;

  /// The read flip. `readAt` is stamped locally for the optimistic paint; the
  /// next fetch replaces it with the server's (first-read-wins) instant.
  AppNotification markedRead({DateTime? at}) => isRead
      ? this
      : AppNotification(
          id: id,
          kind: kind,
          title: title,
          message: message,
          detail: detail,
          action: action,
          createdAt: createdAt,
          isRead: true,
          readAt: at ?? DateTime.now().toUtc(),
        );

  /// DEFENSIVE parse of one feed row. `id`, `title` and `message` are the shape
  /// itself and a row missing them is dropped by the caller (see
  /// [tryFromJson]); every other field degrades — an unknown kind reads as
  /// info, a bad timestamp as epoch, a malformed action as no button.
  static AppNotification? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    final message = json['message'];
    if (id is! String || id.isEmpty) return null;
    if (title is! String || message is! String) return null;

    final detail = json['detail'];
    final createdAtRaw = json['createdAt'];
    final readAtRaw = json['readAt'];
    final readAt =
        (readAtRaw is String ? DateTime.tryParse(readAtRaw) : null)?.toUtc();

    return AppNotification(
      id: id,
      kind: NotificationKind.fromApiValue(
        json['kind'] is String ? json['kind'] as String : null,
      ),
      title: title,
      message: message,
      detail: detail is String && detail.trim().isNotEmpty ? detail : null,
      action: NotificationAction.tryFromJson(json['action']),
      createdAt:
          (createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null)
                  ?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      // A receipt is the truth about read-ness; the flag is the server's
      // summary of it. Either alone is enough — an old backend that sent only
      // the flag still reads correctly.
      isRead: json['isRead'] == true || readAt != null,
      readAt: readAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppNotification &&
          other.id == id &&
          other.kind == kind &&
          other.title == title &&
          other.message == message &&
          other.detail == detail &&
          other.action == action &&
          other.createdAt == createdAt &&
          other.isRead == isRead &&
          other.readAt == readAt;

  @override
  int get hashCode => Object.hash(
        id,
        kind,
        title,
        message,
        detail,
        action,
        createdAt,
        isRead,
        readAt,
      );
}

/// The feed: the rows (newest first, as served) plus the server's unread
/// count. The count is carried rather than derived so the badge shows what the
/// SERVER counted; [withItems] re-derives it after a local read flip, which is
/// the one place the two can legitimately differ until the next fetch.
class NotificationsFeed {
  const NotificationsFeed({required this.items, required this.unreadCount});

  static const empty = NotificationsFeed(items: [], unreadCount: 0);

  final List<AppNotification> items;
  final int unreadCount;

  bool get hasUnread => unreadCount > 0;
  bool get isEmpty => items.isEmpty;

  /// A copy with [items] replaced and the count re-derived from them.
  NotificationsFeed withItems(List<AppNotification> next) => NotificationsFeed(
        items: List.unmodifiable(next),
        unreadCount: next.where((n) => !n.isRead).length,
      );

  /// Parses the `GET /notifications` body. Malformed rows are skipped, not
  /// fatal; a missing/ill-typed list is an empty feed. `unreadCount` falls
  /// back to a local derivation when absent.
  factory NotificationsFeed.fromJson(Map<String, dynamic> json) {
    final raw = json['notifications'];
    final items = <AppNotification>[];
    if (raw is List) {
      for (final row in raw) {
        final parsed = AppNotification.tryFromJson(row);
        if (parsed != null) items.add(parsed);
      }
    }
    final count = json['unreadCount'];
    return NotificationsFeed(
      items: List.unmodifiable(items),
      unreadCount: count is int && count >= 0
          ? count
          : items.where((n) => !n.isRead).length,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationsFeed &&
          other.unreadCount == unreadCount &&
          _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(unreadCount, Object.hashAll(items));

  static bool _listEquals(List<AppNotification> a, List<AppNotification> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
