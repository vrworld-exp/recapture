// lib/domain/catalog/dish_details.dart
//
// Badges and dietary / allergen detail (more-customization Stage 5) — the
// client halves of recapture-api `CatalogBadge`, `PRODUCT_DIETARY`,
// `PRODUCT_ALLERGENS` (models/types/catalog.types.ts). Hand-synced
// (AGENTS.md §0.1). Tags stay exactly as they were; these sit beside them.
import '../entities/product_food_type.dart';

const int kMaxBadges = 12;
const int kMaxBadgeLabel = 18;
const int kMaxProductBadges = 6;

/// Mapped to icons by the presentation layer (and to lucide icons on the menu).
enum BadgeIcon {
  flame('flame'),
  star('star'),
  sparkles('sparkles'),
  leaf('leaf'),
  chefHat('chef-hat'),
  crown('crown'),
  heart('heart'),
  thumbsUp('thumbs-up'),
  clock('clock'),
  percent('percent');

  const BadgeIcon(this.apiValue);
  final String apiValue;

  static BadgeIcon? tryParse(Object? raw) {
    for (final v in values) {
      if (v.apiValue == raw) return v;
    }
    return null;
  }
}

/// `primary` / `accent` follow the menu's theme; the rest are fixed hues.
enum BadgeColor {
  primary('primary', 'Brand'),
  accent('accent', 'Accent'),
  red('red', 'Red'),
  green('green', 'Green'),
  blue('blue', 'Blue'),
  orange('orange', 'Orange');

  const BadgeColor(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static BadgeColor? tryParse(Object? raw) {
    for (final v in values) {
      if (v.apiValue == raw) return v;
    }
    return null;
  }
}

class CatalogBadge {
  const CatalogBadge({this.id, required this.label, required this.icon, required this.color});

  /// Null on a badge not saved yet — the server assigns one.
  final String? id;
  final String label;
  final BadgeIcon icon;
  final BadgeColor color;

  static CatalogBadge? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final icon = BadgeIcon.tryParse(raw['icon']);
    final color = BadgeColor.tryParse(raw['color']);
    if (label is! String || label.trim().isEmpty || icon == null || color == null) return null;
    final id = raw['id'];
    return CatalogBadge(id: id is String ? id : null, label: label, icon: icon, color: color);
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'label': label.trim(),
        'icon': icon.apiValue,
        'color': color.apiValue,
      };

  CatalogBadge copyWith({String? label, BadgeIcon? icon, BadgeColor? color}) => CatalogBadge(
        id: id,
        label: label ?? this.label,
        icon: icon ?? this.icon,
        color: color ?? this.color,
      );

  String? validate() {
    final t = label.trim();
    if (t.isEmpty) return 'Give the badge a name.';
    if (t.length > kMaxBadgeLabel) return 'Keep badge names to $kMaxBadgeLabel characters.';
    return null;
  }

  /// Offered on first open — NOT saved until the owner saves.
  static const List<CatalogBadge> suggestions = [
    CatalogBadge(label: 'Bestseller', icon: BadgeIcon.star, color: BadgeColor.accent),
    CatalogBadge(label: "Chef's special", icon: BadgeIcon.chefHat, color: BadgeColor.primary),
    CatalogBadge(label: 'New', icon: BadgeIcon.sparkles, color: BadgeColor.green),
    CatalogBadge(label: 'Spicy 🌶️', icon: BadgeIcon.flame, color: BadgeColor.red),
    CatalogBadge(label: 'Must try', icon: BadgeIcon.thumbsUp, color: BadgeColor.orange),
    CatalogBadge(label: 'Limited', icon: BadgeIcon.clock, color: BadgeColor.blue),
  ];
}

enum DietaryCode {
  jain('JAIN', 'Jain'),
  vegan('VEGAN', 'Vegan'),
  glutenFree('GLUTEN_FREE', 'Gluten-free'),
  eggless('EGGLESS', 'Eggless'),
  sugarFree('SUGAR_FREE', 'Sugar-free'),
  keto('KETO', 'Keto'),
  highProtein('HIGH_PROTEIN', 'High protein');

  const DietaryCode(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static DietaryCode? tryParse(Object? raw) {
    for (final v in values) {
      if (v.apiValue == raw) return v;
    }
    return null;
  }
}

enum AllergenCode {
  nuts('NUTS', 'Nuts'),
  dairy('DAIRY', 'Dairy'),
  gluten('GLUTEN', 'Gluten'),
  soy('SOY', 'Soy'),
  egg('EGG', 'Egg'),
  shellfish('SHELLFISH', 'Shellfish'),
  sesame('SESAME', 'Sesame');

  const AllergenCode(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static AllergenCode? tryParse(Object? raw) {
    for (final v in values) {
      if (v.apiValue == raw) return v;
    }
    return null;
  }
}

/// A product's Stage 5 detail. Every part optional; a product with none of it
/// renders on the menu exactly as before.
class DishDetails {
  const DishDetails({
    this.badgeIds = const [],
    this.dietary = const {},
    this.allergens = const {},
    this.spiceLevel,
    this.calories,
    this.servesCount,
    this.prepMinutes,
  });

  final List<String> badgeIds;
  final Set<DietaryCode> dietary;
  final Set<AllergenCode> allergens;

  /// 0–3 chillies; null = not stated.
  final int? spiceLevel;
  final int? calories;
  final int? servesCount;
  final int? prepMinutes;

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  /// From a product DTO; missing keys (an older server) read as "none".
  factory DishDetails.fromMap(Map<String, dynamic> map) {
    List<dynamic> list(String k) => map[k] is List ? map[k] as List : const [];
    return DishDetails(
      badgeIds: list('badgeIds').whereType<String>().toList(),
      dietary: list('dietary').map(DietaryCode.tryParse).whereType<DietaryCode>().toSet(),
      allergens: list('allergens').map(AllergenCode.tryParse).whereType<AllergenCode>().toSet(),
      spiceLevel: _int(map['spiceLevel']),
      calories: _int(map['calories']),
      servesCount: _int(map['servesCount']),
      prepMinutes: _int(map['prepMinutes']),
    );
  }

  /// The FULL block, always — `null` clears a number, `[]` clears a list —
  /// so an editor that removes something actually removes it.
  Map<String, dynamic> toPatch() => {
        'badgeIds': badgeIds,
        'dietary': [for (final d in DietaryCode.values) if (dietary.contains(d)) d.apiValue],
        'allergens': [for (final a in AllergenCode.values) if (allergens.contains(a)) a.apiValue],
        'spiceLevel': spiceLevel,
        'calories': calories,
        'servesCount': servesCount,
        'prepMinutes': prepMinutes,
      };

  /// The API's DIET_CONFLICT rule, checked before the round trip.
  String? validate(ProductFoodType foodType) {
    if (foodType == ProductFoodType.nonVeg &&
        (dietary.contains(DietaryCode.vegan) || dietary.contains(DietaryCode.jain))) {
      return 'A vegan or Jain dish cannot also be marked non-veg.';
    }
    if (badgeIds.length > kMaxProductBadges) {
      return 'At most $kMaxProductBadges badges on one dish.';
    }
    return null;
  }

  DishDetails copyWith({
    List<String>? badgeIds,
    Set<DietaryCode>? dietary,
    Set<AllergenCode>? allergens,
    Object? spiceLevel = _keep,
    Object? calories = _keep,
    Object? servesCount = _keep,
    Object? prepMinutes = _keep,
  }) =>
      DishDetails(
        badgeIds: badgeIds ?? this.badgeIds,
        dietary: dietary ?? this.dietary,
        allergens: allergens ?? this.allergens,
        spiceLevel: identical(spiceLevel, _keep) ? this.spiceLevel : spiceLevel as int?,
        calories: identical(calories, _keep) ? this.calories : calories as int?,
        servesCount: identical(servesCount, _keep) ? this.servesCount : servesCount as int?,
        prepMinutes: identical(prepMinutes, _keep) ? this.prepMinutes : prepMinutes as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is DishDetails &&
      _listEq(other.badgeIds, badgeIds) &&
      _setEq(other.dietary, dietary) &&
      _setEq(other.allergens, allergens) &&
      other.spiceLevel == spiceLevel &&
      other.calories == calories &&
      other.servesCount == servesCount &&
      other.prepMinutes == prepMinutes;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(badgeIds),
        Object.hashAllUnordered(dietary),
        Object.hashAllUnordered(allergens),
        spiceLevel,
        calories,
        servesCount,
        prepMinutes,
      );
}

const Object _keep = Object();

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEq<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);
