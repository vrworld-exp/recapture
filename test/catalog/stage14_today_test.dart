// Stage 14 (more-customization): what the Today screen sends, and what it reads back.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/today.dart';

void main() {
  test('an edit sends only what changed', () {
    expect(TodayEdit(inStock: false, untilTomorrow: true).toMap('p1'),
        {'productId': 'p1', 'availability': 'OUT_OF_STOCK', 'untilTomorrow': true});
    expect(TodayEdit(price: 199, priceChanged: true).toMap('p2'), {'productId': 'p2', 'price': 199.0});
    // "until tomorrow" never rides on an in-stock change.
    expect(TodayEdit(inStock: true, untilTomorrow: true).toMap('p3'), {'productId': 'p3', 'availability': 'IN_STOCK'});
  });

  test('parses the Today payload and staff permissions', () {
    final data = TodayData.fromMap({
      'categories': [
        {'id': 'c1', 'name': 'Drinks', 'dishes': [
          {'id': 'p1', 'name': 'Cold_Coffee', 'price': 180, 'availability': 'OUT_OF_STOCK', 'foodType': 'VEG',
           'backInStockAt': '2026-09-29T23:30:00.000Z'},
        ]},
      ],
      'undoablePriceChange': {'id': 'b1', 'at': '2026-09-28T10:00:00.000Z', 'count': 18, 'by': 'Ravi'},
      'lastChanges': [{'at': '2026-09-28T10:00:00.000Z', 'by': 'Ravi', 'kind': 'BULK_PRICE', 'text': 'changed 18 prices'}],
    });
    final dish = data.sections.single.dishes.single;
    expect(dish.inStock, isFalse);
    expect(dish.backInStockAt, isNotNull);
    expect(data.undo?.count, 18);
    final staff = StaffCatalog.fromMap({'catalogId': 'c', 'name': 'Cafe', 'kind': 'STAFF', 'permissions': ['availability', 'publish']});
    expect(staff.permissions.prices, isFalse);
    expect(staff.permissions.publish, isTrue);
  });
}
