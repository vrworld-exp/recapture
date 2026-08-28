// tests/catalog-names.test.ts
//
// The stored form of a catalog/category/product NAME (src/utils/catalogNames.ts)
// — PURE, no DB, no Mirage.
//
// THE POINT OF THIS FILE IS PARITY. `toCatalogSlug` is a port of Mirage's
// (mirage-be/src/helper/helper.js), and the value of storing the slug at all is
// that both databases then hold the SAME string. A drift here is silent: names
// would keep saving, keep displaying, and only fail much later as a duplicate
// Mirage item or a category that will not adopt. So the cases below pin the
// exact output of every rule Mirage applies, in Mirage's order.
import { describe, it, expect } from 'vitest';

import {
  appendSlugSuffix,
  flexibleSlugRegex,
  isValidCatalogSlug,
  toCatalogSlug,
  toDisplayName,
} from '@/utils/catalogNames';

describe('toCatalogSlug', () => {
  it('lowercases and underscores the way Mirage does', () => {
    expect(toCatalogSlug('testing 02')).toBe('testing_02');
    expect(toCatalogSlug('Testing 02')).toBe('testing_02');
    expect(toCatalogSlug('  Blue   Cafe  ')).toBe('blue_cafe');
  });

  it('folds accents onto the base letter instead of dropping them', () => {
    // Order matters: strip-then-fold would make this "caf".
    expect(toCatalogSlug('Café Mocha')).toBe('cafe_mocha');
  });

  it('collapses every separator an admin might type onto one', () => {
    expect(toCatalogSlug('Paneer Tikka - Half')).toBe('paneer_tikka_half');
    expect(toCatalogSlug('A.B.C')).toBe('a_b_c');
    expect(toCatalogSlug('a___b')).toBe('a_b');
  });

  it('drops anything that is not a letter, digit or underscore', () => {
    // These end up in a URL and an S3 key, so they are dropped, not escaped.
    expect(toCatalogSlug('Garden Chairs & Co')).toBe('garden_chairs_co');
    expect(toCatalogSlug('Latte (Large)')).toBe('latte_large');
  });

  it('never leaves a leading or trailing underscore', () => {
    expect(toCatalogSlug('  -Latte-  ')).toBe('latte');
    // Truncation must not expose one either.
    expect(toCatalogSlug('abcde fghij', { maxLength: 6 })).toBe('abcde');
  });

  it('is idempotent — re-slugging a stored name changes nothing', () => {
    // Every comparison path relies on this: a row already in slug form must not
    // drift when it passes through the boundary a second time.
    const once = toCatalogSlug('Café Mocha (Large)');
    expect(toCatalogSlug(once)).toBe(once);
  });

  it('returns empty for a name with nothing sluggable in it', () => {
    // The caller must REJECT this rather than store it — a nameless row is one
    // nothing can search for or address in Mirage.
    for (const input of ['!!!', '   ', '', null, undefined]) {
      expect(toCatalogSlug(input)).toBe('');
      expect(isValidCatalogSlug(toCatalogSlug(input))).toBe(false);
    }
  });
});

describe('appendSlugSuffix', () => {
  it('keeps an auto-generated name in slug form', () => {
    // The failure this prevents: `base + ' (copy)'`, which puts a space and
    // brackets back into a name that was already normalised.
    expect(appendSlugSuffix('latte', 'copy')).toBe('latte_copy');
    expect(appendSlugSuffix('latte', 'copy_2')).toBe('latte_copy_2');
    expect(appendSlugSuffix('blue_cafe', 2)).toBe('blue_cafe_2');
  });
});

describe('flexibleSlugRegex', () => {
  it('finds a stored slug whatever separator the searcher typed', () => {
    const pattern = new RegExp(flexibleSlugRegex('paneer tikka'), 'i');
    expect(pattern.test('paneer_tikka')).toBe(true);
    expect(pattern.test('paneer-tikka')).toBe(true);
    expect(pattern.test('paneertikka')).toBe(true);
    expect(pattern.test('paneer_masala')).toBe(false);
  });

  it('matches regex metacharacters as literal text', () => {
    const pattern = new RegExp(flexibleSlugRegex('a+b'), 'i');
    expect(pattern.test('a+b')).toBe(true);
    expect(pattern.test('aaab')).toBe(false);
  });

  it('anchors on request, for an exact-name lookup', () => {
    const pattern = new RegExp(flexibleSlugRegex('blue cafe', { anchored: true }), 'i');
    expect(pattern.test('blue_cafe')).toBe(true);
    expect(pattern.test('blue_cafe_bakery')).toBe(false);
  });

  it('returns an empty body for all-separator input', () => {
    // A caller must treat this as "no usable pattern": dropped into a filter as
    // a regex it would match every row.
    expect(flexibleSlugRegex('---')).toBe('');
    expect(flexibleSlugRegex('---', { anchored: true })).toBe('^$');
  });
});

describe('toDisplayName', () => {
  it('gives back the spaced form for a UI that wants one', () => {
    expect(toDisplayName('testing_02')).toBe('testing 02');
    expect(toDisplayName(undefined)).toBe('');
  });
});
