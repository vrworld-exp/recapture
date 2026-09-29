// test/catalog/menu_time_test.dart
//
// Opening hours, announcements and category windows as the app AUTHORS them
// (more-customization Stage 4). The rules repeat recapture-api's
// catalogSchemas.ts, so the form refuses what the API would refuse.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/menu_time.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog_category.dart';

import 'catalog_entities_test.dart' as golden;

void main() {
  group('CatalogHours', () {
    const lunch = HoursSlot(day: 1, open: '12:00', close: '15:00');
    const dinner = HoursSlot(day: 1, open: '19:00', close: '01:00');

    test('accepts lunch + a dinner that runs past midnight', () {
      const hours = CatalogHours(weekly: [dinner, lunch]);
      expect(hours.validate(), isNull);
      expect(hours.slotsFor(1), [lunch, dinner]);
      expect(dinner.pastMidnight, isTrue);
    });

    test('refuses overlap, a fourth slot and a zero-length slot', () {
      expect(
        const CatalogHours(weekly: [lunch, HoursSlot(day: 1, open: '14:00', close: '16:00')])
            .validate(),
        contains('overlap'),
      );
      expect(
        const CatalogHours(weekly: [
          HoursSlot(day: 1, open: '19:00', close: '02:00'),
          HoursSlot(day: 1, open: '20:00', close: '21:00'),
        ]).validate(),
        contains('overlap'),
      );
      expect(
        CatalogHours(weekly: [
          for (var h = 1; h <= 4; h++) HoursSlot(day: 2, open: '0$h:00', close: '0$h:30'),
        ]).validate(),
        contains('at most'),
      );
      expect(
        const CatalogHours(weekly: [HoursSlot(day: 3, open: '10:00', close: '10:00')]).validate(),
        isNotNull,
      );
    });

    test('round-trips the wire shape, defaulting zone and badge', () {
      final hours = CatalogHours.fromMap({
        'weekly': [lunch.toMap(), {'day': 9, 'open': '1', 'close': '2'}],
        'closedDates': ['2026-10-20'],
      });
      expect(hours.timezone, kDefaultTimezone);
      expect(hours.showOpenBadge, isTrue);
      expect(hours.weekly, [lunch]);
      expect(hours.toMap()['closedDates'], ['2026-10-20']);
    });

    test('formats times the way a menu says them', () {
      expect(formatMenuTime('07:30'), '7:30 am');
      expect(formatMenuTime('12:00'), '12 pm');
      expect(formatMenuTime('00:00'), '12 am');
    });
  });

  group('CatalogAnnouncement', () {
    final start = DateTime.utc(2026, 10, 17, 18, 30);
    final end = DateTime.utc(2026, 10, 21, 18, 30);
    final diwali = CatalogAnnouncement(text: 'Diwali special', startsAt: start, endsAt: end);

    test('is Scheduled, then Live, then Expired', () {
      expect(diwali.phaseAt(start.subtract(const Duration(minutes: 1))), AnnouncementPhase.scheduled);
      expect(diwali.phaseAt(start), AnnouncementPhase.live);
      expect(diwali.phaseAt(end), AnnouncementPhase.expired);
      expect(const CatalogAnnouncement(text: 'x').phaseAt(DateTime.now()), AnnouncementPhase.live);
    });

    test('validates like the API', () {
      expect(const CatalogAnnouncement(text: '  ').validate(), isNotNull);
      expect(CatalogAnnouncement(text: 'x' * 121).validate(), isNotNull);
      expect(CatalogAnnouncement(text: 'x', startsAt: end, endsAt: start).validate(), isNotNull);
      expect(const CatalogAnnouncement(text: 'x', link: 'javascript:1').validate(), isNotNull);
      expect(diwali.validate(), isNull);
    });

    test('sends dates as UTC ISO strings and parses them back', () {
      final map = diwali.toMap();
      expect(map['startsAt'], '2026-10-17T18:30:00.000Z');
      final back = CatalogAnnouncement.tryParse(map)!;
      expect(back.startsAt, start);
      expect(back.style, AnnouncementStyle.info);
    });
  });

  group('category windows', () {
    test('parse from the category DTO; absent = always, dim by default', () {
      final plain = CatalogCategory.fromMap({'id': 'c1', 'name': 'mains', 'position': 0});
      expect(plain.schedule, isNull);
      expect(plain.hideOutsideWindow, isFalse);

      final breakfast = CatalogCategory.fromMap({
        'id': 'c2',
        'name': 'breakfast',
        'position': 1,
        'schedule': {'days': [5, 1, 1], 'from': '07:00', 'to': '11:00'},
        'outsideWindow': 'hide',
      });
      expect(breakfast.schedule!.days, [1, 5]);
      expect(breakfast.schedule!.label, 'Available 7 am – 11 am');
      expect(breakfast.hideOutsideWindow, isTrue);
    });

    test('refuses an empty or zero-length window', () {
      expect(const CategorySchedule(days: [], from: '07:00', to: '11:00').validate(), isNotNull);
      expect(const CategorySchedule(days: [1], from: '07:00', to: '07:00').validate(), isNotNull);
    });
  });

  test('the business profile carries hours and the announcement, or neither', () {
    final none = BusinessProfile.fromMap(golden.profileGolden());
    expect(none.hours, isNull);
    expect(none.announcement, isNull);

    final set = BusinessProfile.fromMap({
      ...golden.profileGolden(),
      'hours': {'timezone': 'Asia/Kolkata', 'weekly': [], 'closedDates': [], 'showOpenBadge': false},
      'announcement': {'text': 'Now open', 'style': 'offer', 'startsAt': null, 'endsAt': null},
    });
    expect(set.hours!.showOpenBadge, isFalse);
    expect(set.announcement!.style, AnnouncementStyle.offer);
    expect(set.withTimeFields(announcement: null).announcement, isNull);
  });
}
