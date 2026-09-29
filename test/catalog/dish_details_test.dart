// test/catalog/dish_details_test.dart
//
// Badges and dietary / allergen detail as the app authors them (more-
// customization Stage 5). The DIET_CONFLICT rule repeats recapture-api's.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/dish_details.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';

import 'catalog_entities_test.dart' as golden;

void main() {
  group('CatalogBadge', () {
    test('parses, drops malformed entries, and round-trips', () {
      final ok = CatalogBadge.tryParse(
          {'id': 'b1', 'label': "Chef's special", 'icon': 'chef-hat', 'color': 'accent'})!;
      expect(ok.icon, BadgeIcon.chefHat);
      expect(ok.toMap(), {'id': 'b1', 'label': "Chef's special", 'icon': 'chef-hat', 'color': 'accent'});
      expect(CatalogBadge.tryParse({'label': 'X', 'icon': 'rocket', 'color': 'red'}), isNull);
      expect(CatalogBadge.tryParse({'label': ' ', 'icon': 'star', 'color': 'red'}), isNull);
    });

    test('suggestions are valid and unsaved (no id)', () {
      expect(CatalogBadge.suggestions, hasLength(6));
      for (final b in CatalogBadge.suggestions) {
        expect(b.validate(), isNull, reason: b.label);
        expect(b.id, isNull);
      }
      expect(
        CatalogBadge(label: 'x' * 19, icon: BadgeIcon.star, color: BadgeColor.red).validate(),
        isNotNull,
      );
    });
  });

  group('DishDetails', () {
    test('reads nothing from an older product DTO', () {
      final p = CatalogProduct.fromMap({'id': 'p1', 'type': 'IMAGE_ONLY', 'name': 'dal'});
      expect(p.details, const DishDetails());
    });

    test('parses the Stage 5 fields and sends the FULL block', () {
      final d = DishDetails.fromMap({
        'badgeIds': ['b1'],
        'dietary': ['JAIN', 'PALEO'],
        'allergens': ['NUTS'],
        'spiceLevel': 2,
        'servesCount': 2,
        'calories': null,
      });
      expect(d.dietary, {DietaryCode.jain});
      expect(d.toPatch(), {
        'badgeIds': ['b1'],
        'dietary': ['JAIN'],
        'allergens': ['NUTS'],
        'spiceLevel': 2,
        'calories': null,
        'servesCount': 2,
        'prepMinutes': null,
      });
    });

    test('refuses vegan / Jain on a non-veg dish, like the API', () {
      const vegan = DishDetails(dietary: {DietaryCode.vegan});
      expect(vegan.validate(ProductFoodType.nonVeg), isNotNull);
      expect(vegan.validate(ProductFoodType.veg), isNull);
      expect(const DishDetails(dietary: {DietaryCode.keto}).validate(ProductFoodType.nonVeg), isNull);
    });

    test('value equality ignores set order, and copyWith can clear a number', () {
      const a = DishDetails(dietary: {DietaryCode.jain, DietaryCode.vegan}, spiceLevel: 1);
      const b = DishDetails(dietary: {DietaryCode.vegan, DietaryCode.jain}, spiceLevel: 1);
      expect(a, b);
      expect(a.copyWith(spiceLevel: null).spiceLevel, isNull);
      expect(a.copyWith(spiceLevel: null) == a, isFalse);
    });
  });

  test('the business profile carries the badge library', () {
    final profile = BusinessProfile.fromMap({
      ...golden.profileGolden(),
      'badges': [
        {'id': 'b1', 'label': 'New', 'icon': 'sparkles', 'color': 'green'},
        {'id': 'b2', 'label': 'Broken', 'icon': 'rocket', 'color': 'green'},
      ],
    });
    expect(profile.badges.map((b) => b.id), ['b1']);
    expect(BusinessProfile.fromMap(golden.profileGolden()).badges, isEmpty);
  });
}
