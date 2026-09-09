// test/catalog/catalog_names_test.dart
//
// The naming round-trip, which is the thing that broke: a catalog, category or
// product name is STORED as a slug, and the client used to print that slug and
// diff against it. Users then "fixed" the spelling by retyping it, the retype
// normalised straight back to the stored value, and the rename appeared to be
// ignored — in the catalog and, because nothing had changed to publish, on the
// Mirage menu too.
//
// These tests pin both halves of the fix:
//   • the display form is what a person reads;
//   • "did it change?" is answered on the SLUG, so a case-or-separator-only
//     edit is correctly not a change and a real rename correctly is.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/catalog_names.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_type.dart';

void main() {
  group('catalogSlug — a faithful port of the server rule', () {
    test('lowercases and collapses every separator onto one underscore', () {
      expect(catalogSlug('  Chicken   Biryani '), 'chicken_biryani');
      expect(catalogSlug('Chicken-Biryani'), 'chicken_biryani');
      expect(catalogSlug('Chicken.Biryani'), 'chicken_biryani');
      expect(catalogSlug('CHICKEN BIRYANI'), 'chicken_biryani');
    });

    test('drops punctuation rather than transliterating it', () {
      expect(catalogSlug('Ravi\'s Café & Co.'), 'ravis_cafe_co');
    });

    test('folds accents onto the base letter instead of eating them', () {
      // The whole reason the fold runs BEFORE the strip: without it "Café"
      // becomes "caf" and stops matching what the server stored.
      expect(catalogSlug('Café'), 'cafe');
      expect(catalogSlug('Piñata'), 'pinata');
    });

    test('is idempotent — slugging a stored name returns it unchanged', () {
      // The property the dirty check depends on.
      expect(catalogSlug('chicken_biryani'), 'chicken_biryani');
    });

    test('answers empty for a name with nothing usable in it', () {
      // The server rejects this rather than storing it, so callers must treat
      // it as "there was no name in there".
      expect(catalogSlug('!!!'), '');
      expect(catalogSlug('   '), '');
      expect(catalogSlug(null), '');
    });

    test('never leaves a trailing underscore after a truncation', () {
      expect(catalogSlug('ab cd', maxLength: 3), 'ab');
    });
  });

  group('catalogDisplayName', () {
    test('puts the underscores back as spaces', () {
      expect(catalogDisplayName('chicken_biryani'), 'chicken biryani');
      expect(catalogDisplayName('cafe'), 'cafe');
      expect(catalogDisplayName(null), '');
    });
  });

  group('catalogNameChanged — the check that used to lie', () {
    const stored = 'chicken_biryani';

    test('the display form of the stored name is NOT a change', () {
      // THE BUG. The field is seeded with "chicken biryani"; raw equality
      // called that a rename, sent it, and the server normalised it back to
      // what was already there — a save that changed nothing while the UI
      // reported success.
      expect(catalogNameChanged('chicken biryani', stored), isFalse);
    });

    test('a case- or separator-only edit is NOT a change', () {
      expect(catalogNameChanged('Chicken Biryani', stored), isFalse);
      expect(catalogNameChanged('Chicken-Biryani', stored), isFalse);
      expect(catalogNameChanged('  chicken   biryani  ', stored), isFalse);
    });

    test('a real rename IS a change', () {
      expect(catalogNameChanged('Chicken Biryani Special', stored), isTrue);
      expect(catalogNameChanged('Mutton Biryani', stored), isTrue);
    });

    test('respects the field bound it is given', () {
      // A category caps at 80, a product at 120. Comparing a long name under
      // the wrong bound would report a change the server would not make.
      final long = 'a' * 90;
      expect(
        catalogNameChanged(long, 'a' * 80, maxLength: kMaxCategoryNameLength),
        isFalse,
      );
    });
  });

  group('entities expose the readable name', () {
    test('a product', () {
      const product = CatalogProduct(
        id: 'p1',
        type: ProductType.imageOnly,
        name: 'chicken_biryani',
        currency: 'INR',
        position: 0,
      );
      expect(product.name, 'chicken_biryani'); // what goes to the API
      expect(product.displayName, 'chicken biryani'); // what goes on screen
    });

    test('a category', () {
      const category =
          CatalogCategory(id: 'c1', name: 'main_course', position: 0);
      expect(category.displayName, 'main course');
    });
  });
}
