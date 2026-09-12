// lib/domain/entities/product_food_type.dart

/// The veg / non-veg marker a dish carries on the public menu.
///
/// PUBLISHED — unlike availability and featured, this one reaches customers:
/// the public card draws a green square for [veg], a red one for [nonVeg], and
/// nothing at all for [none]. Three values rather than a bool because "no
/// label" is a real answer a bool cannot give — a bakery or a furniture
/// showroom has no use for the distinction.
///
/// [veg] is THE DEFAULT. A dish nobody classified is vegetarian, which is what
/// the public page has always rendered for an item with no marker, so a
/// backend that predates the field leaves every card looking exactly as it
/// did. Only an explicit choice of [nonVeg] or [none] is ever sent.
enum ProductFoodType { veg, nonVeg, none }

extension ProductFoodTypeX on ProductFoodType {
  /// The word on the segmented row in the editors.
  String get label => switch (this) {
        ProductFoodType.veg => 'Veg',
        ProductFoodType.nonVeg => 'Non-veg',
        ProductFoodType.none => 'No label',
      };

  /// Whether the public card draws a marker for this value at all.
  bool get showsMarker => this != ProductFoodType.none;

  /// API string value — must match the backend `PRODUCT_FOOD_TYPES` exactly.
  String get apiValue => switch (this) {
        ProductFoodType.veg => 'VEG',
        ProductFoodType.nonVeg => 'NON_VEG',
        ProductFoodType.none => 'NONE',
      };

  /// Anything unrecognised — including the absent field an older server sends —
  /// is [veg], the value the public page renders for an unclassified dish.
  static ProductFoodType fromApiValue(String? value) =>
      switch ((value ?? '').toUpperCase()) {
        'NON_VEG' => ProductFoodType.nonVeg,
        'NONE' => ProductFoodType.none,
        _ => ProductFoodType.veg,
      };
}
