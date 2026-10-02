// lib/domain/catalog/today.dart
//
// The Today screen and staff access (more-customization
// Stage 14), as the API returns them.

String _s(Object? v) => v is String ? v : '';
double? _n(Object? v) => v is num ? v.toDouble() : null;

class TodayDish {
  const TodayDish({
    required this.id,
    required this.name,
    required this.price,
    required this.inStock,
    required this.foodType,
    this.backInStockAt,
  });

  final String id;
  final String name;
  final double? price;
  final bool inStock;
  final String foodType;

  /// Set when "sold out until tomorrow" will put it back.
  final DateTime? backInStockAt;

  factory TodayDish.fromMap(Map<String, dynamic> m) => TodayDish(
        id: _s(m['id']),
        name: _s(m['name']),
        price: _n(m['price']),
        inStock: m['availability'] != 'OUT_OF_STOCK',
        foodType: _s(m['foodType']),
        backInStockAt: DateTime.tryParse(_s(m['backInStockAt'])),
      );
}

class TodaySection {
  const TodaySection({required this.id, required this.name, required this.dishes});
  final String? id;
  final String name;
  final List<TodayDish> dishes;
}

class TodayChangeLine {
  const TodayChangeLine({required this.at, required this.by, required this.text});
  final DateTime? at;
  final String by;
  final String text;
}

class TodayData {
  const TodayData({required this.sections, required this.lastChanges, this.undo});

  final List<TodaySection> sections;
  final List<TodayChangeLine> lastChanges;

  /// The newest bulk price change that can still be undone.
  final ({String by, int count, DateTime? at})? undo;

  factory TodayData.fromMap(Map<String, dynamic>? map) {
    final m = map ?? const <String, dynamic>{};
    final undo = m['undoablePriceChange'];
    return TodayData(
      sections: [
        for (final c in (m['categories'] is List ? m['categories'] as List : const []))
          if (c is Map<String, dynamic>)
            TodaySection(
              id: c['id'] is String ? c['id'] as String : null,
              name: _s(c['name']),
              dishes: [
                for (final d in (c['dishes'] is List ? c['dishes'] as List : const []))
                  if (d is Map<String, dynamic>) TodayDish.fromMap(d),
              ],
            ),
      ],
      lastChanges: [
        for (final r in (m['lastChanges'] is List ? m['lastChanges'] as List : const []))
          if (r is Map)
            TodayChangeLine(at: DateTime.tryParse(_s(r['at'])), by: _s(r['by']), text: _s(r['text'])),
      ],
      undo: undo is Map
          ? (by: _s(undo['by']), count: undo['count'] is int ? undo['count'] as int : 0, at: DateTime.tryParse(_s(undo['at'])))
          : null,
    );
  }
}

/// One pending change on the Today screen.
class TodayEdit {
  TodayEdit({this.inStock, this.untilTomorrow = false, this.price, this.priceChanged = false});

  bool? inStock;
  bool untilTomorrow;
  double? price;
  bool priceChanged;

  Map<String, dynamic> toMap(String productId) => {
        'productId': productId,
        if (inStock != null) 'availability': inStock! ? 'IN_STOCK' : 'OUT_OF_STOCK',
        if (inStock == false && untilTomorrow) 'untilTomorrow': true,
        if (priceChanged) 'price': price,
      };
}

enum PriceRounding {
  none('NONE', 'No rounding'),
  five('FIVE', 'To ₹5'),
  nine('NINE', 'End in 9');

  const PriceRounding(this.apiValue, this.label);
  final String apiValue;
  final String label;
}

class BulkPreviewRow {
  const BulkPreviewRow({required this.name, required this.from, this.to});
  final String name;
  final double from;
  final double? to;
}

/// What a helper may do (the server enforces it; the app only hides buttons).
class StaffPermissions {
  const StaffPermissions(this.values);
  final List<String> values;

  static const owner = StaffPermissions(['availability', 'prices', 'publish']);

  bool get prices => values.contains('prices');
  bool get publish => values.contains('publish');
}

class StaffMember {
  const StaffMember({
    required this.id,
    required this.invited,
    required this.manager,
    this.name,
    this.phone,
  });

  final String id;

  /// Invited but has not signed in yet.
  final bool invited;
  final bool manager;
  final String? name;
  final String? phone;

  factory StaffMember.fromMap(Map<String, dynamic> m) => StaffMember(
        id: _s(m['id']),
        invited: m['status'] == 'INVITED',
        manager: m['kind'] == 'MANAGER',
        name: m['name'] is String ? m['name'] as String : null,
        phone: m['phone'] is String ? m['phone'] as String : null,
      );
}

class StaffCatalog {
  const StaffCatalog({required this.catalogId, required this.name, required this.manager, required this.permissions});

  final String catalogId;
  final String name;
  final bool manager;
  final StaffPermissions permissions;

  factory StaffCatalog.fromMap(Map<String, dynamic> m) => StaffCatalog(
        catalogId: _s(m['catalogId']),
        name: _s(m['name']),
        manager: m['kind'] == 'MANAGER',
        permissions: StaffPermissions([
          for (final p in (m['permissions'] is List ? m['permissions'] as List : const []))
            if (p is String) p,
        ]),
      );
}
