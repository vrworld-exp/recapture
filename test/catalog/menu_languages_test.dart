// test/catalog/menu_languages_test.dart
//
// Multi-language menus (more-customization Stage 6):
//   • the languages block and every translation map parse defensively — an
//     older server (no keys at all) reads as English only, nothing translated;
//   • progress counts dishes with a NAME in the language;
//   • the Translations screen puts untranslated dishes first, and a quick edit
//     saves exactly that dish in exactly that language;
//   • an English-only menu is offered the language picker instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/data/repositories/menu_translations_repository.dart';
import 'package:recapture/domain/catalog/menu_languages.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/presentation/screens/catalog/translations_screen.dart';

import 'catalog_entities_test.dart' as golden;

CatalogProduct _dish(String id, String name, [Map<String, dynamic>? i18n]) => CatalogProduct.fromMap({
      'id': id,
      'type': 'IMAGE_ONLY',
      'name': name,
      'currency': 'INR',
      'position': 0,
      if (i18n != null) 'i18n': i18n,
    });

BusinessProfile _profile({Map<String, dynamic>? languages}) =>
    BusinessProfile.fromMap({...golden.profileGolden(), 'languages': languages});

class _FakeRepo implements MenuTranslationsRepository {
  _FakeRepo(this.data);

  final MenuTranslationsData data;
  final List<(String, MenuLanguage, DishTranslation)> dishWrites = [];

  @override
  Future<MenuTranslationsData?> load() async => data;

  @override
  Future<CatalogProduct> updateDish(String productId, MenuLanguage lang, DishTranslation t) async {
    dishWrites.add((productId, lang, t));
    final current = data.products.firstWhere((p) => p.id == productId);
    return current.copyWith(i18n: {...current.i18n, lang: t});
  }

  @override
  Future<BusinessProfile> updateLanguages(MenuLanguages languages) => throw UnimplementedError();

  @override
  Future<BusinessProfile> updateCatalogText(MenuLanguage lang, CatalogLanguageText text) =>
      throw UnimplementedError();

  @override
  Future<CatalogCategory> updateCategory(String categoryId, MenuLanguage lang, String name) =>
      throw UnimplementedError();
}

Future<_FakeRepo> _pump(WidgetTester tester, MenuTranslationsData data) async {
  final repo = _FakeRepo(data);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [menuTranslationsRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: TranslationsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  group('parsing', () {
    test('an older server reads as English only, nothing translated', () {
      final profile = BusinessProfile.fromMap(golden.profileGolden());
      expect(profile.languages, MenuLanguages.englishOnly);
      expect(profile.i18n, isEmpty);
      expect(_dish('d1', 'paneer').i18n, isEmpty);
    });

    test('languages: unknown and repeated codes dropped, primary never an extra', () {
      final l = MenuLanguages.fromMap({
        'primary': 'en',
        'extra': ['hi', 'fr', 'en', 'hi', 'ta'],
      });
      expect(l.primary, MenuLanguage.en);
      expect(l.extra, [MenuLanguage.hi, MenuLanguage.ta]);
      expect(l.toMap(), {
        'primary': 'en',
        'extra': ['hi', 'ta'],
      });
    });

    test('dish translations round-trip; blanks and unknown languages dropped', () {
      final d = _dish('d1', 'paneer', {
        'hi': {'name': 'पनीर', 'description': '  '},
        'xx': {'name': 'nope'},
        'ta': {'name': ''},
      });
      expect(d.i18n.keys, [MenuLanguage.hi]);
      expect(d.i18n[MenuLanguage.hi]!.name, 'पनीर');
      expect(d.i18n[MenuLanguage.hi]!.description, isNull);
      expect(CatalogProduct.fromMap(d.toMap()).i18n[MenuLanguage.hi]!.name, 'पनीर');
    });

    test('progress counts dishes with a name in the language', () {
      final dishes = [
        _dish('a', 'a', {'hi': {'name': 'ए'}}).i18n,
        _dish('b', 'b', {'hi': {'description': 'only a description'}}).i18n,
        _dish('c', 'c').i18n,
      ];
      final p = TranslationProgress.of(dishes, MenuLanguage.hi);
      expect((p.translated, p.total, p.percent), (1, 3, 33));
      expect(TranslationProgress.of(const [], MenuLanguage.hi).percent, 100);
    });
  });

  group('TranslationsScreen', () {
    testWidgets('an English-only menu is offered the language picker', (tester) async {
      await _pump(
        tester,
        MenuTranslationsData(profile: _profile(), products: [_dish('d1', 'paneer')], categories: const []),
      );
      expect(find.text('Your menu is in one language'), findsOneWidget);
      expect(find.text('Choose languages'), findsOneWidget);
    });

    testWidgets('untranslated first; a quick edit saves that dish in that language', (tester) async {
      final repo = await _pump(
        tester,
        MenuTranslationsData(
          profile: _profile(languages: {
            'primary': 'en',
            'extra': ['hi'],
          }),
          products: [
            _dish('d1', 'paneer_tikka', {'hi': {'name': 'पनीर टिक्का'}}),
            _dish('d2', 'dal_makhani'),
          ],
          categories: const [],
        ),
      );

      expect(find.text('Hindi · हिन्दी · 50%'), findsOneWidget);
      // The untranslated dish is listed before the translated one.
      final dal = tester.getTopLeft(find.byKey(const Key('translations-dish-d2')));
      final paneer = tester.getTopLeft(find.byKey(const Key('translations-dish-d1')));
      expect(dal.dy, lessThan(paneer.dy));
      expect(find.text('Not translated'), findsOneWidget);

      await tester.tap(find.byKey(const Key('translations-dish-d2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('translation-dish-name')), ' दाल मखनी ');
      await tester.tap(find.byKey(const Key('translation-dish-save')));
      await tester.pumpAndSettle();

      expect(repo.dishWrites, hasLength(1));
      final (id, lang, t) = repo.dishWrites.single;
      expect((id, lang, t.name), ('d2', MenuLanguage.hi, 'दाल मखनी'));
      expect(find.text('दाल मखनी'), findsOneWidget);
      expect(find.text('Hindi · हिन्दी · 100%'), findsOneWidget);
    });
  });
}
