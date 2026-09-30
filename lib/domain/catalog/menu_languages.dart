// lib/domain/catalog/menu_languages.dart
//
// Multi-language menus (more-customization Stage 6) — the client half of
// recapture-api `MENU_LANGUAGES`, `CatalogLanguages` and the translation maps
// (models/types/catalog.types.ts). Hand-synced (AGENTS.md §0.1).
//
// The primary text stays where it always was (a dish's name and description,
// the announcement, a badge's label). Translations sit BESIDE it, one map per
// language, and the owner types every one (no machine translation — Q3). The
// public menu falls back to the primary text wherever a translation is missing,
// so a half-translated menu is a normal, working state.

/// Maximum extra languages a menu may offer — mirrors MAX_EXTRA_LANGUAGES.
const int kMaxExtraLanguages = 3;

/// Every language a menu can be written in.
enum MenuLanguage {
  en('en', 'English', 'English'),
  hi('hi', 'Hindi', 'हिन्दी'),
  mr('mr', 'Marathi', 'मराठी'),
  gu('gu', 'Gujarati', 'ગુજરાતી'),
  ta('ta', 'Tamil', 'தமிழ்'),
  te('te', 'Telugu', 'తెలుగు'),
  kn('kn', 'Kannada', 'ಕನ್ನಡ'),
  bn('bn', 'Bengali', 'বাংলা'),
  pa('pa', 'Punjabi', 'ਪੰਜਾਬੀ'),
  ml('ml', 'Malayalam', 'മലയാളം');

  const MenuLanguage(this.code, this.englishName, this.nativeName);

  /// The API value (`hi`).
  final String code;
  final String englishName;

  /// The name in its own script — what the menu's switcher shows.
  final String nativeName;

  /// "Hindi · हिन्दी" — English first so the owner can read it, the native
  /// name second so they can check it.
  String get label => this == en ? englishName : '$englishName · $nativeName';

  static MenuLanguage? tryParse(Object? raw) {
    for (final v in values) {
      if (v.code == raw) return v;
    }
    return null;
  }
}

/// Which languages the menu is offered in. [extra] never contains [primary].
class MenuLanguages {
  const MenuLanguages({this.primary = MenuLanguage.en, this.extra = const []});

  final MenuLanguage primary;
  final List<MenuLanguage> extra;

  static const MenuLanguages englishOnly = MenuLanguages();

  bool get hasExtra => extra.isNotEmpty;

  /// Defensive: an older server sends nothing (English only), and anything
  /// unknown or repeated is dropped rather than crashing the screen.
  factory MenuLanguages.fromMap(Object? raw) {
    if (raw is! Map) return englishOnly;
    final primary = MenuLanguage.tryParse(raw['primary']) ?? MenuLanguage.en;
    final extra = <MenuLanguage>[];
    final rawExtra = raw['extra'];
    if (rawExtra is List) {
      for (final code in rawExtra) {
        final lang = MenuLanguage.tryParse(code);
        if (lang != null && lang != primary && !extra.contains(lang)) extra.add(lang);
      }
    }
    return MenuLanguages(primary: primary, extra: extra.take(kMaxExtraLanguages).toList());
  }

  Map<String, dynamic> toMap() => {
        'primary': primary.code,
        'extra': [for (final l in extra) l.code],
      };

  /// Same rules as catalogSchemas.ts `languagesSchema`.
  String? validate() {
    if (extra.length > kMaxExtraLanguages) {
      return 'Pick at most $kMaxExtraLanguages extra languages.';
    }
    if (extra.contains(primary)) return 'An extra language cannot be the main one.';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MenuLanguages &&
      other.primary == primary &&
      other.extra.length == extra.length &&
      [for (var i = 0; i < extra.length; i++) other.extra[i] == extra[i]].every((same) => same);

  @override
  int get hashCode => Object.hash(primary, Object.hashAll(extra));
}

/// A dish's name / description in one language. Either may be missing.
class DishTranslation {
  const DishTranslation({this.name, this.description});

  final String? name;
  final String? description;

  bool get isEmpty => (name ?? '').trim().isEmpty && (description ?? '').trim().isEmpty;

  /// Blank fields are left out — the server drops them anyway.
  Map<String, dynamic> toMap() => {
        if ((name ?? '').trim().isNotEmpty) 'name': name!.trim(),
        if ((description ?? '').trim().isNotEmpty) 'description': description!.trim(),
      };
}

/// The catalog-level text in one language: the announcement and badge labels
/// (by badge id).
class CatalogLanguageText {
  const CatalogLanguageText({this.announcement, this.badges = const {}});

  final String? announcement;
  final Map<String, String> badges;

  bool get isEmpty => (announcement ?? '').trim().isEmpty && badges.values.every((l) => l.trim().isEmpty);

  Map<String, dynamic> toMap() {
    final labels = {
      for (final e in badges.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
    return {
      if ((announcement ?? '').trim().isNotEmpty) 'announcement': announcement!.trim(),
      if (labels.isNotEmpty) 'badges': labels,
    };
  }
}

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// `{ hi: { name, description } }` from a product DTO. Unknown languages and
/// non-string values are dropped.
Map<MenuLanguage, DishTranslation> parseDishTranslations(Object? raw) {
  if (raw is! Map) return const {};
  final out = <MenuLanguage, DishTranslation>{};
  raw.forEach((code, entry) {
    final lang = MenuLanguage.tryParse(code);
    if (lang == null || entry is! Map) return;
    final t = DishTranslation(name: _text(entry['name']), description: _text(entry['description']));
    if (!t.isEmpty) out[lang] = t;
  });
  return out;
}

/// `{ hi: { name } }` from a category DTO, as language → name.
Map<MenuLanguage, String> parseNameTranslations(Object? raw) {
  if (raw is! Map) return const {};
  final out = <MenuLanguage, String>{};
  raw.forEach((code, entry) {
    final lang = MenuLanguage.tryParse(code);
    final name = entry is Map ? _text(entry['name']) : null;
    if (lang != null && name != null) out[lang] = name;
  });
  return out;
}

/// `{ hi: { announcement, badges: { id: label } } }` from the profile DTO.
Map<MenuLanguage, CatalogLanguageText> parseCatalogTranslations(Object? raw) {
  if (raw is! Map) return const {};
  final out = <MenuLanguage, CatalogLanguageText>{};
  raw.forEach((code, entry) {
    final lang = MenuLanguage.tryParse(code);
    if (lang == null || entry is! Map) return;
    final badges = <String, String>{};
    final rawBadges = entry['badges'];
    if (rawBadges is Map) {
      rawBadges.forEach((id, label) {
        final text = _text(label);
        if (id is String && text != null) badges[id] = text;
      });
    }
    final t = CatalogLanguageText(announcement: _text(entry['announcement']), badges: badges);
    if (!t.isEmpty) out[lang] = t;
  });
  return out;
}

/// How much of the menu is translated into [lang]: dishes whose NAME has a
/// translation, out of [dishes]. The name is what a diner scans for, so it is
/// what "translated" means here; a missing description falls back quietly.
class TranslationProgress {
  const TranslationProgress({required this.translated, required this.total});

  final int translated;
  final int total;

  /// 0–100, rounded down so "99%" never reads as done. An empty menu is 100%.
  int get percent => total == 0 ? 100 : (translated * 100) ~/ total;

  bool get isComplete => translated >= total;

  static TranslationProgress of(
    Iterable<Map<MenuLanguage, DishTranslation>> dishes,
    MenuLanguage lang,
  ) {
    var total = 0;
    var translated = 0;
    for (final dish in dishes) {
      total++;
      if ((dish[lang]?.name ?? '').trim().isNotEmpty) translated++;
    }
    return TranslationProgress(translated: translated, total: total);
  }
}
