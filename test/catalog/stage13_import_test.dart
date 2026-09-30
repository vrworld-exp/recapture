// Stage 13 (more-customization): page type from bytes, and the draft the API returns.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/menu_import.dart';
import 'package:recapture/presentation/screens/catalog/menu_import_screen.dart';

void main() {
  test('sniffs the page type from the bytes, not the name', () {
    expect(sniffPageType(Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D])), 'application/pdf');
    expect(sniffPageType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
    expect(sniffPageType(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])), 'image/png');
    expect(sniffPageType(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  test('parses a ready import with matches and low-confidence rows', () {
    final m = MenuImport.fromMap({
      'id': 'i1',
      'status': 'READY',
      'pages': 2,
      'pagesDone': 2,
      'draft': {
        'currency': 'INR',
        'categories': [
          {
            'name': 'Starters',
            'items': [
              {'key': 'd1', 'name': 'Paneer Tikka', 'price': 250, 'foodType': 'VEG', 'confidence': 0.95, 'variants': []},
              {'key': 'd2', 'name': 'Dal', 'price': null, 'foodType': 'NONE', 'confidence': 0.4, 'variants': [
                {'label': 'Half', 'price': 120}, {'label': 'Full', 'price': 220},
              ]},
            ],
          },
        ],
        'duplicatesDropped': ['Paneer Tikka'],
      },
      'matches': {'d1': {'productId': 'p1', 'name': 'Paneer Tikka', 'price': 240}},
    });
    expect(m.status, MenuImportStatus.ready);
    expect(m.categories.single.items.map((i) => i.lowConfidence), [false, true]);
    expect(m.categories.single.items[1].variants.length, 2);
    expect(m.matches['d1']?.price, 240);
    expect(m.duplicatesDropped, ['Paneer Tikka']);
  });
}
