// lib/domain/catalog/menu_theme_presets.dart
//
// The Mirage menu looks an owner can pick on the Appearance screen
// (more-customization Stage 2).
//
// The palettes are owned by mirage-fe (src/theme/presets.ts) and mirrored in
// recapture-api (config/themePresets.ts), which serves them — every colour
// already RESOLVED, button colours included — on /remote-config as
// `themePresets`. [MenuThemePreset.bundled] is the same list baked in, so the
// screen works on first launch, offline, and against an older server; keep it
// equal to the API's THEME_PRESETS_WIRE.

/// Every colour the public menu paints, as `#RRGGBB`.
class MenuThemeColors {
  const MenuThemeColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.text2,
    required this.primary,
    required this.accent,
    required this.overlay,
    required this.onPrimary,
    required this.ctaFrom,
    required this.ctaTo,
  });

  final String bg;
  final String surface;
  final String surface2;
  final String text;
  final String text2;
  final String primary;
  final String accent;
  final String overlay;

  /// Text on a primary-coloured fill (the AR button, the active tab).
  final String onPrimary;

  /// The primary-button gradient.
  final String ctaFrom;
  final String ctaTo;

  static final RegExp _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');

  /// Null when any colour is missing or malformed — a half-parsed palette would
  /// preview a menu that does not exist.
  static MenuThemeColors? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    String? c(String key) {
      final v = raw[key];
      return v is String && _hex.hasMatch(v) ? v.toUpperCase() : null;
    }

    final values = [
      for (final k in const [
        'bg', 'surface', 'surface2', 'text', 'text2', 'primary', 'accent', //
        'overlay', 'onPrimary', 'ctaFrom', 'ctaTo',
      ])
        c(k),
    ];
    if (values.any((v) => v == null)) return null;
    return MenuThemeColors(
      bg: values[0]!,
      surface: values[1]!,
      surface2: values[2]!,
      text: values[3]!,
      text2: values[4]!,
      primary: values[5]!,
      accent: values[6]!,
      overlay: values[7]!,
      onPrimary: values[8]!,
      ctaFrom: values[9]!,
      ctaTo: values[10]!,
    );
  }

  MenuThemeColors copyWith({
    String? primary,
    String? accent,
    String? onPrimary,
    String? ctaFrom,
    String? ctaTo,
  }) =>
      MenuThemeColors(
        bg: bg,
        surface: surface,
        surface2: surface2,
        text: text,
        text2: text2,
        primary: primary ?? this.primary,
        accent: accent ?? this.accent,
        overlay: overlay,
        onPrimary: onPrimary ?? this.onPrimary,
        ctaFrom: ctaFrom ?? this.ctaFrom,
        ctaTo: ctaTo ?? this.ctaTo,
      );

  Map<String, dynamic> toMap() => {
        'bg': bg,
        'surface': surface,
        'surface2': surface2,
        'text': text,
        'text2': text2,
        'primary': primary,
        'accent': accent,
        'overlay': overlay,
        'onPrimary': onPrimary,
        'ctaFrom': ctaFrom,
        'ctaTo': ctaTo,
      };
}

class MenuThemePreset {
  const MenuThemePreset({
    required this.id,
    required this.label,
    required this.isDark,
    required this.colors,
  });

  final String id;
  final String label;
  final bool isDark;
  final MenuThemeColors colors;

  static const String defaultId = 'basalt';

  static MenuThemePreset? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final label = raw['label'];
    final mode = raw['mode'];
    final colors = MenuThemeColors.tryParse(raw['colors']);
    if (id is! String || id.isEmpty || label is! String || colors == null) {
      return null;
    }
    if (mode != 'dark' && mode != 'light') return null;
    return MenuThemePreset(id: id, label: label, isDark: mode == 'dark', colors: colors);
  }

  /// The served list, or [bundled] whole when it is absent or any entry is
  /// malformed — the server's own reject-to-defaults, and the same shape as
  /// `PlanCatalog.fromMapOrDefault`. A list without Basalt is rejected too:
  /// it is the fallback every other rule leans on.
  static List<MenuThemePreset> listFromOrDefault(dynamic raw) {
    if (raw is! List || raw.isEmpty) return bundled;
    final parsed = <MenuThemePreset>[];
    for (final entry in raw) {
      final preset = tryParse(entry);
      if (preset == null) return bundled;
      parsed.add(preset);
    }
    if (!parsed.any((p) => p.id == defaultId)) return bundled;
    return List.unmodifiable(parsed);
  }

  /// [id] in [presets], or Basalt — the fallback Mirage-fe itself applies.
  static MenuThemePreset resolve(String? id, List<MenuThemePreset> presets) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    for (final p in presets) {
      if (p.id == defaultId) return p;
    }
    return bundled.first;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'mode': isDark ? 'dark' : 'light',
        'colors': colors.toMap(),
      };

  /// Mirrors recapture-api THEME_PRESETS_WIRE value for value. Basalt first.
  static const List<MenuThemePreset> bundled = [
    MenuThemePreset(
      id: 'basalt',
      label: 'Basalt',
      isDark: true,
      colors: MenuThemeColors(
        bg: '#0B0B0E',
        surface: '#151518',
        surface2: '#1A1A24',
        text: '#F5F5F7',
        text2: '#B3B3B8',
        primary: '#E10600',
        accent: '#C9A24D',
        overlay: '#000000',
        onPrimary: '#F5F5F7',
        ctaFrom: '#8B1A1A',
        ctaTo: '#A52422',
      ),
    ),
    MenuThemePreset(
      id: 'midnight-gold',
      label: 'Fine Dine',
      isDark: true,
      colors: MenuThemeColors(
        bg: '#0B1220',
        surface: '#131C2E',
        surface2: '#1A2540',
        text: '#F3F4F8',
        text2: '#A9B1C6',
        primary: '#D4AF37',
        accent: '#E8D5A3',
        overlay: '#000000',
        onPrimary: '#0B1220',
        ctaFrom: '#C29D2E',
        ctaTo: '#DDBB4E',
      ),
    ),
    MenuThemePreset(
      id: 'espresso',
      label: 'Café',
      isDark: true,
      colors: MenuThemeColors(
        bg: '#1B1411',
        surface: '#261C17',
        surface2: '#30241E',
        text: '#F5EBDD',
        text2: '#C9B8A6',
        primary: '#D08A4E',
        accent: '#E6C79C',
        overlay: '#000000',
        onPrimary: '#1B1411',
        ctaFrom: '#BF7F48',
        ctaTo: '#D69863',
      ),
    ),
    MenuThemePreset(
      id: 'street',
      label: 'Street Food',
      isDark: true,
      colors: MenuThemeColors(
        bg: '#121212',
        surface: '#1C1C1C',
        surface2: '#262626',
        text: '#F5F5F5',
        text2: '#B0B0B0',
        primary: '#FFC400',
        accent: '#FF7A45',
        overlay: '#000000',
        onPrimary: '#121212',
        ctaFrom: '#EBB400',
        ctaTo: '#FFCB1F',
      ),
    ),
    MenuThemePreset(
      id: 'garden',
      label: 'Fresh & Green',
      isDark: false,
      colors: MenuThemeColors(
        bg: '#F7F9F4',
        surface: '#FFFFFF',
        surface2: '#EAF1E3',
        text: '#1C2A1C',
        text2: '#4F5F4F',
        primary: '#2E7D32',
        accent: '#8F5200',
        overlay: '#F7F9F4',
        onPrimary: '#FFFFFF',
        ctaFrom: '#1D4E1F',
        ctaTo: '#225B25',
      ),
    ),
    MenuThemePreset(
      id: 'bakery',
      label: 'Bakery',
      isDark: false,
      colors: MenuThemeColors(
        bg: '#FFF8F3',
        surface: '#FFFFFF',
        surface2: '#FBE9E7',
        text: '#3B2A2A',
        text2: '#6E5A58',
        primary: '#C2185B',
        accent: '#A0522D',
        overlay: '#FFF8F3',
        onPrimary: '#FFFFFF',
        ctaFrom: '#780F38',
        ctaTo: '#8E1242',
      ),
    ),
    MenuThemePreset(
      id: 'ocean',
      label: 'Seafood',
      isDark: false,
      colors: MenuThemeColors(
        bg: '#F5FAFB',
        surface: '#FFFFFF',
        surface2: '#E3F1F3',
        text: '#0F2A33',
        text2: '#47626B',
        primary: '#00695C',
        accent: '#B3541E',
        overlay: '#F5FAFB',
        onPrimary: '#FFFFFF',
        ctaFrom: '#004139',
        ctaTo: '#004D43',
      ),
    ),
    MenuThemePreset(
      id: 'royal',
      label: 'Royal Indian',
      isDark: true,
      colors: MenuThemeColors(
        bg: '#2A0A12',
        surface: '#3A1019',
        surface2: '#4A1622',
        text: '#FFF4E6',
        text2: '#E0C3B0',
        primary: '#F29F05',
        accent: '#E8C468',
        overlay: '#000000',
        onPrimary: '#2A0A12',
        ctaFrom: '#DF9205',
        ctaTo: '#F4AB23',
      ),
    ),
  ];
}
