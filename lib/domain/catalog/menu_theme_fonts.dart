// lib/domain/catalog/menu_theme_fonts.dart
//
// The menu font pairings an owner can pick (more-customization Stage 3).
//
// Owned by mirage-fe (src/theme/fonts.ts), mirrored in recapture-api
// (config/themePresets.ts THEME_FONTS) which serves them on /remote-config as
// `themeFonts`. [bundled] is the same list baked in. The app does not render the
// fonts themselves (that would pull Google Fonts into the app); it shows the
// pairing's name and families.

class MenuThemeFont {
  const MenuThemeFont({required this.id, required this.label, required this.sample});

  final String id;
  final String label;

  /// "Heading / Body" family names, shown under the label.
  final String sample;

  static const String defaultId = 'default';

  static MenuThemeFont? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final label = raw['label'];
    final sample = raw['sample'];
    if (id is! String || id.isEmpty || label is! String || label.isEmpty) return null;
    return MenuThemeFont(id: id, label: label, sample: sample is String ? sample : '');
  }

  /// The served list, or [bundled] whole on anything malformed — the same
  /// reject-to-defaults as the presets. A list without `default` is rejected.
  static List<MenuThemeFont> listFromOrDefault(dynamic raw) {
    if (raw is! List || raw.isEmpty) return bundled;
    final parsed = <MenuThemeFont>[];
    for (final entry in raw) {
      final font = tryParse(entry);
      if (font == null) return bundled;
      parsed.add(font);
    }
    if (!parsed.any((f) => f.id == defaultId)) return bundled;
    return List.unmodifiable(parsed);
  }

  Map<String, dynamic> toMap() => {'id': id, 'label': label, 'sample': sample};

  static const List<MenuThemeFont> bundled = [
    MenuThemeFont(id: 'default', label: 'Default', sample: 'Poppins'),
    MenuThemeFont(id: 'classic', label: 'Classic', sample: 'Playfair Display / Inter'),
    MenuThemeFont(id: 'modern', label: 'Modern', sample: 'Poppins'),
    MenuThemeFont(id: 'friendly', label: 'Friendly', sample: 'Baloo 2 / Nunito'),
    MenuThemeFont(id: 'bold', label: 'Bold', sample: 'Bebas Neue / Roboto'),
    MenuThemeFont(id: 'elegant', label: 'Elegant', sample: 'Cormorant Garamond / Lato'),
    MenuThemeFont(id: 'hindi', label: 'Hindi', sample: 'Tiro Devanagari Hindi / Mukta'),
  ];
}
