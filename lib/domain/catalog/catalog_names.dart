// lib/domain/catalog/catalog_names.dart
//
// The ONE place this client turns a catalog, category or product NAME into the
// form the backend STORES, and back into the form a person reads.
//
// WHY THIS FILE EXISTS. Every catalog/category/product name is stored as a
// lowercase underscore slug — "cafe_mocha" — because the name doubles as the
// public URL segment and as an S3 key prefix on Mirage, neither of which
// tolerates a raw space. Both backends already enforce that:
//   recapture-api/src/utils/catalogNames.ts  (the Zod boundary, on the way IN)
//   mirage-be/src/helper/helper.js           (again, on the way in to Mirage)
//
// The underscore is an INTERNAL detail and must never reach a screen — Mirage's
// own public menu de-slugs everything it prints (mirage-fe removeCharacters.ts,
// `removeUnderScore`). This client did not, and that is the whole bug this file
// closes:
//
//   • the catalog showed "chicken_biryani" where the user typed "Chicken
//     Biryani", so every name looked wrong;
//   • so users retyped it — and "Chicken Biryani" slugs to the value already
//     stored, so the PATCH changed nothing while the UI still said "saved".
//     The rename appeared to be ignored, in the catalog AND on the menu, for
//     products, categories and the restaurant name alike.
//
// So: [catalogDisplayName] is the only thing that goes on a screen or into an
// input the user edits, and [catalogNameChanged] — never raw string equality —
// is what decides whether a name was actually edited.
//
// ⚠ KEEP IN LOCKSTEP WITH recapture-api/src/utils/catalogNames.ts. A rule that
// drifts here does not corrupt anything (the server slugs again regardless),
// but it makes this client's "did it change?" answer disagree with the
// server's, which is exactly the confusion above.

/// `Catalog.name` / `CatalogProduct.name`'s bound. Mirrors the backend Zod max.
const int kCatalogNameMaxLength = 120;

/// Accents folded onto their base letter BEFORE the strip below.
///
/// The backends do this with `String.normalize('NFD')` + a diacritic strip,
/// which Dart's core library has no equivalent for. This table covers the
/// Latin-1 Supplement and the common Latin Extended-A letters, which is the
/// range a restaurant name realistically uses ("Café", "Piñata", "Škoda").
///
/// A letter this table misses is DROPPED rather than transliterated, exactly as
/// an un-normalised diacritic would be on the server — so the two sides still
/// agree on the stored value. The only cost of a gap is a redundant PATCH that
/// the server no-ops.
const Map<String, String> _foldedLetters = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ă': 'a', 'ą': 'a',
  'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c',
  'ď': 'd', 'đ': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e',
  'ę': 'e', 'ě': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g',
  'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i',
  'į': 'i', 'ı': 'i',
  'ĵ': 'j',
  'ķ': 'k',
  'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ŏ': 'o', 'ő': 'o',
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r',
  'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's',
  'ţ': 't', 'ť': 't', 'ŧ': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u',
  'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ŵ': 'w',
  'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
  'ź': 'z', 'ż': 'z', 'ž': 'z',
};

final RegExp _separators = RegExp(r'[\s\-.]+');
final RegExp _notSlugChar = RegExp(r'[^a-z0-9_]');
final RegExp _runsOfUnderscore = RegExp(r'_+');
final RegExp _edgeUnderscores = RegExp(r'^_+|_+$');
final RegExp _trailingUnderscores = RegExp(r'_+$');

/// The STORED form of a name: lowercase, underscore-separated, ASCII-ish.
///
/// Returns `''` for input with no letters or digits at all ("!!!", "   ", an
/// all-emoji name) — the server rejects that rather than storing it, so a
/// caller must treat an empty result as "there was no name in there".
///
/// [maxLength] defaults to the catalog/product bound; pass
/// [kMaxCategoryNameLength] for a category, so this never truncates somewhere
/// the server would not.
String catalogSlug(String? value, {int maxLength = kCatalogNameMaxLength}) {
  if (value == null) return '';

  final folded = StringBuffer();
  for (final char in value.trim().toLowerCase().split('')) {
    folded.write(_foldedLetters[char] ?? char);
  }

  final slug = folded
      .toString()
      // Every separator a person might type collapses to the same one.
      .replaceAll(_separators, '_')
      // Anything that is not a letter, digit or underscore is DROPPED rather
      // than transliterated — it would end up in a URL and an S3 key.
      .replaceAll(_notSlugChar, '')
      .replaceAll(_runsOfUnderscore, '_')
      .replaceAll(_edgeUnderscores, '');

  final capped =
      slug.length <= maxLength ? slug : slug.substring(0, maxLength);
  return capped.replaceAll(_trailingUnderscores, '');
}

/// The form a person reads: the stored slug with its underscores back as
/// spaces.
///
/// This is what belongs on every screen and in every input the user edits. It
/// is deliberately NOT title-cased — the stored name is lowercase and inventing
/// capitals here would show the user a name the menu does not print.
String catalogDisplayName(String? value) {
  if (value == null) return '';
  return value.replaceAll('_', ' ').trim();
}

/// Did the user actually rename this?
///
/// The ONLY correct test, and the reason raw `typed != stored` is a bug: the
/// field holds the DISPLAY form ("Chicken Biryani") while [stored] holds the
/// slug ("chicken_biryani"), so string equality reports a change on every
/// screen open — and then reports "saved" for a PATCH that changed nothing.
///
/// Comparing slugs also gets the honest answer for the edits that only look
/// like renames: "Chicken-Biryani", "CHICKEN BIRYANI" and "chicken  biryani"
/// all store as what is already there, so none of them is a change.
bool catalogNameChanged(
  String typed,
  String stored, {
  int maxLength = kCatalogNameMaxLength,
}) =>
    catalogSlug(typed, maxLength: maxLength) !=
    catalogSlug(stored, maxLength: maxLength);
