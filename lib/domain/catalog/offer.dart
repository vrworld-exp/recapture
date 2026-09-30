// lib/domain/catalog/offer.dart
//
// Offers, combos and happy-hour pricing (more-customization Stage 10), as the
// API's `/catalog/offers` returns them. The server owns every decision — the
// status chip, the price previews, the save-time checks — so nothing here
// computes a price.

enum OfferKind {
  percent('PERCENT'),
  flat('FLAT'),
  fixedPrice('FIXED_PRICE'),
  combo('COMBO');

  const OfferKind(this.apiValue);
  final String apiValue;

  static OfferKind fromApiValue(String? v) =>
      OfferKind.values.firstWhere((k) => k.apiValue == v, orElse: () => OfferKind.percent);
}

enum OfferTargetType {
  products('PRODUCTS'),
  categories('CATEGORIES'),
  all('ALL');

  const OfferTargetType(this.apiValue);
  final String apiValue;

  static OfferTargetType fromApiValue(String? v) =>
      OfferTargetType.values.firstWhere((k) => k.apiValue == v, orElse: () => OfferTargetType.all);
}

enum OfferStatus {
  live('LIVE', 'Live now'),
  scheduled('SCHEDULED', 'Scheduled'),
  ended('ENDED', 'Ended'),
  paused('PAUSED', 'Paused');

  const OfferStatus(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static OfferStatus fromApiValue(String? v) =>
      OfferStatus.values.firstWhere((k) => k.apiValue == v, orElse: () => OfferStatus.scheduled);
}

/// At most this many offers switched on at once (the server enforces it).
const int kMaxActiveOffers = 20;
const int kMaxOfferName = 30;
const int kMaxComboTitle = 40;
const int kMaxComboDishes = 10;

List<String> _ids(Object? v) => v is List ? v.whereType<String>().toList() : const [];
double? _num(Object? v) => v is num ? v.toDouble() : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

class OfferSchedule {
  const OfferSchedule({this.startsAt, this.endsAt, this.days = const [], this.from, this.to});

  /// Overall validity, either bound optional.
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// 0 = Sunday … 6 = Saturday. Empty = every day.
  final List<int> days;

  /// "HH:mm" — the daily window, in the restaurant's time (India).
  final String? from;
  final String? to;

  bool get hasDailyWindow => from != null && to != null;

  factory OfferSchedule.fromMap(Map<String, dynamic>? map) {
    final m = map ?? const <String, dynamic>{};
    return OfferSchedule(
      startsAt: DateTime.tryParse(_str(m['startsAt']) ?? ''),
      endsAt: DateTime.tryParse(_str(m['endsAt']) ?? ''),
      days: m['days'] is List ? (m['days'] as List).whereType<int>().toList() : const [],
      from: _str(m['from']),
      to: _str(m['to']),
    );
  }

  Map<String, dynamic> toMap() => {
        if (startsAt != null) 'startsAt': startsAt!.toUtc().toIso8601String(),
        if (endsAt != null) 'endsAt': endsAt!.toUtc().toIso8601String(),
        if (days.isNotEmpty) 'days': days,
        if (hasDailyWindow) 'from': from,
        if (hasDailyWindow) 'to': to,
      };
}

class Offer {
  const Offer({
    required this.name,
    required this.kind,
    this.id,
    this.value,
    this.targetType = OfferTargetType.products,
    this.targetIds = const [],
    this.comboProductIds = const [],
    this.comboPrice,
    this.comboTitle,
    this.schedule = const OfferSchedule(),
    this.active = true,
    this.priority = 0,
    this.status = OfferStatus.scheduled,
  });

  /// Null for an offer not saved yet.
  final String? id;
  final String name;
  final OfferKind kind;

  /// 20 (%), 50 (₹ off) or 199 (₹ new price). Null on a combo.
  final double? value;
  final OfferTargetType targetType;
  final List<String> targetIds;
  final List<String> comboProductIds;
  final double? comboPrice;
  final String? comboTitle;
  final OfferSchedule schedule;
  final bool active;

  /// When two offers hit one dish, the LOWER number wins.
  final int priority;
  final OfferStatus status;

  factory Offer.fromMap(Map<String, dynamic> map) {
    final target = map['target'] is Map<String, dynamic> ? map['target'] as Map<String, dynamic> : const {};
    final combo = map['combo'] is Map<String, dynamic> ? map['combo'] as Map<String, dynamic> : null;
    return Offer(
      id: _str(map['id']),
      name: _str(map['name']) ?? '',
      kind: OfferKind.fromApiValue(map['kind'] as String?),
      value: _num(map['value']),
      targetType: OfferTargetType.fromApiValue(target['type'] as String?),
      targetIds: _ids(target['ids']),
      comboProductIds: _ids(combo?['productIds']),
      comboPrice: _num(combo?['price']),
      comboTitle: _str(combo?['title']),
      schedule: OfferSchedule.fromMap(
        map['schedule'] is Map<String, dynamic> ? map['schedule'] as Map<String, dynamic> : null,
      ),
      active: map['active'] != false,
      priority: map['priority'] is int ? map['priority'] as int : 0,
      status: OfferStatus.fromApiValue(map['status'] as String?),
    );
  }

  /// The body POST / PUT / preview send — the whole offer, every time.
  Map<String, dynamic> toMap() => {
        'name': name.trim(),
        'kind': kind.apiValue,
        if (kind != OfferKind.combo && value != null) 'value': value,
        if (kind != OfferKind.combo)
          'target': {
            'type': targetType.apiValue,
            'ids': targetType == OfferTargetType.all ? const <String>[] : targetIds,
          },
        if (kind == OfferKind.combo)
          'combo': {
            'productIds': comboProductIds,
            'price': comboPrice ?? 0,
            if ((comboTitle ?? '').trim().isNotEmpty) 'title': comboTitle!.trim(),
          },
        'schedule': schedule.toMap(),
        'active': active,
        'priority': priority,
      };

  /// "−20%", "₹50 off", "₹199", "Combo ₹299".
  String get valueLabel => switch (kind) {
        OfferKind.percent => '−${_fmt(value)}%',
        OfferKind.flat => '₹${_fmt(value)} off',
        OfferKind.fixedPrice => '₹${_fmt(value)}',
        OfferKind.combo => 'Combo ₹${_fmt(comboPrice)}',
      };
}

String _fmt(double? v) {
  if (v == null) return '';
  return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}

/// `POST /catalog/offers/preview`.
class OfferPreview {
  const OfferPreview({required this.affectedCount, required this.samples, this.comboFullPrice, this.comboSaves});

  final int affectedCount;
  final List<({String name, double? price, double? finalPrice})> samples;
  final double? comboFullPrice;
  final double? comboSaves;

  factory OfferPreview.fromMap(Map<String, dynamic>? map) {
    final m = map ?? const <String, dynamic>{};
    final combo = m['combo'] is Map<String, dynamic> ? m['combo'] as Map<String, dynamic> : null;
    return OfferPreview(
      affectedCount: m['affectedCount'] is int ? m['affectedCount'] as int : 0,
      samples: [
        for (final s in (m['samples'] is List ? m['samples'] as List : const []))
          if (s is Map<String, dynamic>)
            (name: _str(s['name']) ?? '', price: _num(s['price']), finalPrice: _num(s['final'])),
      ],
      comboFullPrice: _num(combo?['fullPrice']),
      comboSaves: _num(combo?['saves']),
    );
  }
}

/// One offer on a product — the product editor's "On offer" line.
class ProductOffer {
  const ProductOffer({required this.name, required this.kind, required this.status, this.value, this.finalPrice, this.wins = false});

  final String name;
  final OfferKind kind;
  final double? value;
  final OfferStatus status;
  final double? finalPrice;
  final bool wins;

  factory ProductOffer.fromMap(Map<String, dynamic> map) => ProductOffer(
        name: _str(map['name']) ?? '',
        kind: OfferKind.fromApiValue(map['kind'] as String?),
        value: _num(map['value']),
        status: OfferStatus.fromApiValue(map['status'] as String?),
        finalPrice: _num(map['final']),
        wins: map['wins'] == true,
      );

  /// "Happy hour (−20%)".
  String get label => '$name (${Offer(name: name, kind: kind, value: value).valueLabel})';
}
