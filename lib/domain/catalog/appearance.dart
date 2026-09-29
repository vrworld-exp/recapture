// lib/domain/catalog/appearance.dart
//
// How the public Mirage menu LOOKS (more-customization Stages 2–3) — the client
// half of recapture-api `CatalogAppearance` (models/types/catalog.types.ts).
//
// Hand-synced, like every shared shape here (AGENTS.md §0.1). Every key is
// optional: an absent appearance is the default Basalt page.
import '../entities/catalog_json.dart';

/// How dish cards are drawn on the public menu (Stage 3).
enum MenuLayout {
  /// Today's two-per-screen card. The default.
  grid('grid', 'Grid', 'Big cards, two per screen'),

  /// Compact rows with a small photo — long menus, dhabas, bars.
  list('list', 'List', 'Compact rows for long menus'),

  /// Full-width 4:3 photo cards — few, photogenic dishes.
  large('large', 'Large', 'Big photos for a short menu');

  const MenuLayout(this.apiValue, this.label, this.help);

  final String apiValue;
  final String label;
  final String help;

  /// Null for absent or unknown — which the menu draws as [grid].
  static MenuLayout? tryParse(Object? raw) {
    for (final l in values) {
      if (l.apiValue == raw) return l;
    }
    return null;
  }
}

class CatalogAppearance {
  const CatalogAppearance({
    this.presetId,
    this.mode,
    this.primary,
    this.accent,
    this.layout,
    this.fontId,
  });

  /// One of the served / bundled preset ids (see menu_theme_presets.dart).
  final String? presetId;

  /// 'dark' | 'light'. Informational — every current preset fixes its own.
  final String? mode;

  /// `#RRGGBB` overrides; null = the preset's own colour.
  final String? primary;
  final String? accent;

  /// Stage 3. Null = [MenuLayout.grid].
  final MenuLayout? layout;

  /// Stage 3. A font pairing id (menu_theme_fonts.dart); null = default fonts.
  final String? fontId;

  bool get isEmpty =>
      presetId == null &&
      mode == null &&
      primary == null &&
      accent == null &&
      layout == null &&
      fontId == null;

  /// Field by field — an unknown key from a newer server is dropped rather than
  /// carried into a `.strict()` write that would then be refused.
  factory CatalogAppearance.fromMap(Map<String, dynamic> map) => CatalogAppearance(
        presetId: catalogText(map['presetId']),
        mode: catalogText(map['mode']),
        primary: catalogText(map['primary'])?.toUpperCase(),
        accent: catalogText(map['accent'])?.toUpperCase(),
        layout: MenuLayout.tryParse(map['layout']),
        fontId: catalogText(map['fontId']),
      );

  /// Only set keys: the server REPLACES the block, so an absent key is a
  /// cleared one — which is exactly what "use the preset's colour" means.
  Map<String, dynamic> toMap() => {
        if (presetId != null) 'presetId': presetId,
        if (mode != null) 'mode': mode,
        if (primary != null) 'primary': primary,
        if (accent != null) 'accent': accent,
        if (layout != null) 'layout': layout!.apiValue,
        if (fontId != null) 'fontId': fontId,
      };

  /// Nullable fields take a sentinel so "clear the accent" is expressible.
  CatalogAppearance copyWith({
    Object? presetId = _keep,
    Object? primary = _keep,
    Object? accent = _keep,
    Object? layout = _keep,
    Object? fontId = _keep,
  }) =>
      CatalogAppearance(
        presetId: identical(presetId, _keep) ? this.presetId : presetId as String?,
        mode: mode,
        primary: identical(primary, _keep) ? this.primary : primary as String?,
        accent: identical(accent, _keep) ? this.accent : accent as String?,
        layout: identical(layout, _keep) ? this.layout : layout as MenuLayout?,
        fontId: identical(fontId, _keep) ? this.fontId : fontId as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is CatalogAppearance &&
      other.presetId == presetId &&
      other.mode == mode &&
      other.primary == primary &&
      other.accent == accent &&
      other.layout == layout &&
      other.fontId == fontId;

  @override
  int get hashCode => Object.hash(presetId, mode, primary, accent, layout, fontId);
}

const Object _keep = Object();
