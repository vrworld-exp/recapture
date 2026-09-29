// lib/domain/catalog/menu_time.dart
//
// Opening hours, the announcement strip and category availability windows
// (more-customization Stage 4) — the client halves of recapture-api
// `CatalogHours`, `CatalogAnnouncement` and `CategorySchedule`
// (models/types/catalog.types.ts). Hand-synced (AGENTS.md §0.1).
//
// The app only AUTHORS these. "Is it open now?" is answered on the public page
// in the restaurant's timezone (decision D7), which is why nothing here needs a
// timezone database.

/// Mirrored from recapture-api catalogSchemas.ts — checked here only so the
/// form can say so before a round trip.
const int kMaxSlotsPerDay = 3;
const int kMaxFutureClosedDates = 60;
const int kMaxAnnouncementLength = 120;
const String kDefaultTimezone = 'Asia/Kolkata';

final RegExp _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// Day names, index = the API's day number (0 = Sunday).
const List<String> kWeekdayNames = [
  'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
];

/// Monday-first display order.
const List<int> kWeekOrder = [1, 2, 3, 4, 5, 6, 0];

int minutesOf(String hhmm) =>
    int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3, 5));

/// "7:30 am" — the way a menu says a time.
String formatMenuTime(String hhmm) {
  final total = minutesOf(hhmm);
  final h24 = total ~/ 60;
  final m = total % 60;
  final suffix = h24 < 12 ? 'am' : 'pm';
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return m == 0 ? '$h12 $suffix' : '$h12:${m.toString().padLeft(2, '0')} $suffix';
}

class HoursSlot {
  const HoursSlot({required this.day, required this.open, required this.close});

  final int day;
  final String open;
  final String close;

  /// A slot closing at or before it opens runs past midnight.
  bool get pastMidnight => minutesOf(close) <= minutesOf(open);

  static HoursSlot? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final day = raw['day'];
    final open = raw['open'];
    final close = raw['close'];
    if (day is! int || day < 0 || day > 6) return null;
    if (open is! String || !_hhmm.hasMatch(open)) return null;
    if (close is! String || !_hhmm.hasMatch(close)) return null;
    return HoursSlot(day: day, open: open, close: close);
  }

  Map<String, dynamic> toMap() => {'day': day, 'open': open, 'close': close};

  HoursSlot copyWith({int? day, String? open, String? close}) =>
      HoursSlot(day: day ?? this.day, open: open ?? this.open, close: close ?? this.close);

  @override
  bool operator ==(Object other) =>
      other is HoursSlot && other.day == day && other.open == open && other.close == close;

  @override
  int get hashCode => Object.hash(day, open, close);
}

class CatalogHours {
  const CatalogHours({
    this.timezone = kDefaultTimezone,
    this.weekly = const [],
    this.closedDates = const [],
    this.showOpenBadge = true,
  });

  final String timezone;
  final List<HoursSlot> weekly;

  /// 'YYYY-MM-DD'.
  final List<String> closedDates;
  final bool showOpenBadge;

  List<HoursSlot> slotsFor(int day) =>
      weekly.where((s) => s.day == day).toList()
        ..sort((a, b) => minutesOf(a.open).compareTo(minutesOf(b.open)));

  factory CatalogHours.fromMap(Map<String, dynamic> map) {
    final rawWeekly = map['weekly'];
    final rawDates = map['closedDates'];
    return CatalogHours(
      timezone: map['timezone'] is String && (map['timezone'] as String).isNotEmpty
          ? map['timezone'] as String
          : kDefaultTimezone,
      weekly: rawWeekly is List
          ? rawWeekly.map(HoursSlot.tryParse).whereType<HoursSlot>().toList()
          : const [],
      closedDates: rawDates is List ? rawDates.whereType<String>().toList() : const [],
      showOpenBadge: map['showOpenBadge'] != false,
    );
  }

  Map<String, dynamic> toMap() => {
        'timezone': timezone,
        'weekly': [for (final s in weekly) s.toMap()],
        'closedDates': closedDates,
        'showOpenBadge': showOpenBadge,
      };

  CatalogHours copyWith({
    List<HoursSlot>? weekly,
    List<String>? closedDates,
    bool? showOpenBadge,
  }) =>
      CatalogHours(
        timezone: timezone,
        weekly: weekly ?? this.weekly,
        closedDates: closedDates ?? this.closedDates,
        showOpenBadge: showOpenBadge ?? this.showOpenBadge,
      );

  /// The first problem the API would refuse, in words, or null. Same rules as
  /// catalogSchemas.ts `hoursSchema`: ≤ 3 slots a day, no overlap (a
  /// past-midnight slot measured to its real end), no zero-length slot, at most
  /// 60 upcoming holidays.
  String? validate({DateTime? today}) {
    for (final day in kWeekOrder) {
      final slots = slotsFor(day);
      if (slots.length > kMaxSlotsPerDay) {
        return '${kWeekdayNames[day]}: at most $kMaxSlotsPerDay time slots.';
      }
      for (final s in slots) {
        if (s.open == s.close) {
          return '${kWeekdayNames[day]}: a slot cannot open and close at the same time.';
        }
      }
      for (var i = 1; i < slots.length; i++) {
        final prev = slots[i - 1];
        final prevEnd = minutesOf(prev.close) + (prev.pastMidnight ? 24 * 60 : 0);
        if (minutesOf(slots[i].open) < prevEnd) {
          return '${kWeekdayNames[day]}: two time slots overlap.';
        }
      }
    }
    final now = today ?? DateTime.now();
    final todayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final upcoming = closedDates.toSet().where((d) => d.compareTo(todayKey) >= 0).length;
    if (upcoming > kMaxFutureClosedDates) {
      return 'At most $kMaxFutureClosedDates upcoming holidays.';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogHours &&
      other.timezone == timezone &&
      other.showOpenBadge == showOpenBadge &&
      _listEq(other.weekly, weekly) &&
      _listEq(other.closedDates, closedDates);

  @override
  int get hashCode =>
      Object.hash(timezone, showOpenBadge, Object.hashAll(weekly), Object.hashAll(closedDates));
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

enum AnnouncementStyle {
  info('info', 'Info'),
  offer('offer', 'Offer'),
  alert('alert', 'Alert');

  const AnnouncementStyle(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static AnnouncementStyle parse(Object? raw) =>
      values.firstWhere((s) => s.apiValue == raw, orElse: () => AnnouncementStyle.info);
}

/// Where an announcement's date window stands, for the "Scheduled / Live /
/// Expired" label. It only goes live on the menu once PUBLISHED, but after that
/// the window runs on its own.
enum AnnouncementPhase { scheduled, live, expired }

class CatalogAnnouncement {
  const CatalogAnnouncement({
    required this.text,
    this.emoji,
    this.style = AnnouncementStyle.info,
    this.startsAt,
    this.endsAt,
    this.link,
  });

  final String text;
  final String? emoji;
  final AnnouncementStyle style;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String? link;

  AnnouncementPhase phaseAt(DateTime now) {
    if (startsAt != null && now.isBefore(startsAt!)) return AnnouncementPhase.scheduled;
    if (endsAt != null && !now.isBefore(endsAt!)) return AnnouncementPhase.expired;
    return AnnouncementPhase.live;
  }

  static CatalogAnnouncement? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final emoji = raw['emoji'];
    final link = raw['link'];
    return CatalogAnnouncement(
      text: text,
      emoji: emoji is String && emoji.isNotEmpty ? emoji : null,
      style: AnnouncementStyle.parse(raw['style']),
      startsAt: date(raw['startsAt']),
      endsAt: date(raw['endsAt']),
      link: link is String && link.isNotEmpty ? link : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'text': text.trim(),
        if (emoji != null && emoji!.isNotEmpty) 'emoji': emoji,
        'style': style.apiValue,
        if (startsAt != null) 'startsAt': startsAt!.toUtc().toIso8601String(),
        if (endsAt != null) 'endsAt': endsAt!.toUtc().toIso8601String(),
        if (link != null && link!.isNotEmpty) 'link': link,
      };

  /// Same rules as catalogSchemas.ts `announcementSchema`.
  String? validate() {
    final t = text.trim();
    if (t.isEmpty) return 'Write the announcement first.';
    if (t.length > kMaxAnnouncementLength) {
      return 'Keep it to $kMaxAnnouncementLength characters.';
    }
    if (startsAt != null && endsAt != null && !endsAt!.isAfter(startsAt!)) {
      return 'The end date must be after the start date.';
    }
    final l = link;
    if (l != null && l.isNotEmpty && !RegExp(r'^https?://', caseSensitive: false).hasMatch(l)) {
      return 'The link must start with http:// or https://';
    }
    return null;
  }
}

class CategorySchedule {
  const CategorySchedule({required this.days, required this.from, required this.to});

  /// 0 = Sunday … 6 = Saturday.
  final List<int> days;
  final String from;
  final String to;

  /// "Available 7 am – 11 am" — what the menu shows when the section is dimmed.
  String get label => 'Available ${formatMenuTime(from)} – ${formatMenuTime(to)}';

  static CategorySchedule? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final days = raw['days'];
    final from = raw['from'];
    final to = raw['to'];
    if (days is! List || from is! String || to is! String) return null;
    if (!_hhmm.hasMatch(from) || !_hhmm.hasMatch(to)) return null;
    final parsed = days.whereType<int>().where((d) => d >= 0 && d <= 6).toSet().toList()..sort();
    if (parsed.isEmpty) return null;
    return CategorySchedule(days: parsed, from: from, to: to);
  }

  Map<String, dynamic> toMap() => {'days': days, 'from': from, 'to': to};

  String? validate() {
    if (days.isEmpty) return 'Pick at least one day.';
    if (from == to) return 'The start and end times must differ.';
    return null;
  }
}
