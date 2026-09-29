// lib/domain/catalog/appearance.dart
//
// How the public Mirage menu LOOKS (more-customization Stage 2) — the client
// half of recapture-api `CatalogAppearance` (models/types/catalog.types.ts).
//
// Hand-synced, like every shared shape here (AGENTS.md §0.1). Every key is
// optional: an absent appearance is the default Basalt page.
import '../entities/catalog_json.dart';

class CatalogAppearance {
  const CatalogAppearance({this.presetId, this.mode, this.primary, this.accent});

  /// One of the served / bundled preset ids (see menu_theme_presets.dart).
  final String? presetId;

  /// 'dark' | 'light'. Informational — every current preset fixes its own.
  final String? mode;

  /// `#RRGGBB` overrides; null = the preset's own colour.
  final String? primary;
  final String? accent;

  bool get isEmpty =>
      presetId == null && mode == null && primary == null && accent == null;

  /// Field by field — an unknown key from a newer server is dropped rather than
  /// carried into a `.strict()` write that would then be refused.
  factory CatalogAppearance.fromMap(Map<String, dynamic> map) => CatalogAppearance(
        presetId: catalogText(map['presetId']),
        mode: catalogText(map['mode']),
        primary: catalogText(map['primary'])?.toUpperCase(),
        accent: catalogText(map['accent'])?.toUpperCase(),
      );

  /// Only set keys: the server REPLACES the block, so an absent key is a
  /// cleared one — which is exactly what "use the preset's colour" means.
  Map<String, dynamic> toMap() => {
        if (presetId != null) 'presetId': presetId,
        if (mode != null) 'mode': mode,
        if (primary != null) 'primary': primary,
        if (accent != null) 'accent': accent,
      };

  /// Nullable fields take a sentinel so "clear the accent" is expressible.
  CatalogAppearance copyWith({
    Object? presetId = _keep,
    Object? primary = _keep,
    Object? accent = _keep,
  }) =>
      CatalogAppearance(
        presetId: identical(presetId, _keep) ? this.presetId : presetId as String?,
        mode: mode,
        primary: identical(primary, _keep) ? this.primary : primary as String?,
        accent: identical(accent, _keep) ? this.accent : accent as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is CatalogAppearance &&
      other.presetId == presetId &&
      other.mode == mode &&
      other.primary == primary &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(presetId, mode, primary, accent);
}

const Object _keep = Object();
