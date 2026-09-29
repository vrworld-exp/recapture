// lib/application/catalog/appearance_notifier.dart
//
// The Appearance screen's working copy (more-customization Stage 2).
//
// The SAVED appearance lives on the business profile ([businessProfileFor]) —
// this notifier only holds what the owner is trying out: a preset and two
// optional colours, whether that differs from what is saved, and whether it is
// readable. Saving goes through the profile notifier, so there is one write
// path and one "draft changes not yet live" refresh for both scopes.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../domain/catalog/appearance.dart';
import '../../domain/catalog/catalog_scope.dart';
import '../../domain/catalog/color_contrast.dart';
import '../../domain/catalog/menu_theme_fonts.dart';
import '../../domain/catalog/menu_theme_presets.dart';
import '../config/config_notifier.dart';
import 'business_profile_notifier.dart';

@immutable
class AppearanceDraft {
  const AppearanceDraft({
    required this.saved,
    required this.draft,
    this.saving = false,
    this.error,
  });

  /// What the server holds; null = the default page.
  final CatalogAppearance? saved;

  /// What the screen shows. Never null — the default look is Basalt, stated.
  final CatalogAppearance draft;

  final bool saving;
  final CatalogFailure? error;

  /// Compared as the server would store them: an all-empty draft IS "no
  /// appearance", so picking Basalt with no colours on a catalog that never
  /// chose one is not a change.
  bool get isDirty => _normalise(draft) != _normalise(saved);

  static CatalogAppearance? _normalise(CatalogAppearance? a) {
    if (a == null) return null;
    final isPlainBasalt = (a.presetId == null || a.presetId == MenuThemePreset.defaultId) &&
        a.primary == null &&
        a.accent == null &&
        (a.layout == null || a.layout == MenuLayout.grid) &&
        (a.fontId == null || a.fontId == MenuThemeFont.defaultId) &&
        !a.showFilters;
    return isPlainBasalt ? null : a;
  }

  AppearanceDraft copyWith({
    CatalogAppearance? saved,
    bool clearSaved = false,
    CatalogAppearance? draft,
    bool? saving,
    Object? error = _keep,
  }) =>
      AppearanceDraft(
        saved: clearSaved ? null : (saved ?? this.saved),
        draft: draft ?? this.draft,
        saving: saving ?? this.saving,
        error: identical(error, _keep) ? this.error : error as CatalogFailure?,
      );
}

const Object _keep = Object();

/// One working copy per [CatalogScope] — the owner's own and each delegated
/// restaurant keep separate drafts. autoDispose: leaving the screen drops an
/// unsaved try-out, which is what "Cancel" means here.
class AppearanceNotifier
    extends AutoDisposeFamilyNotifier<AppearanceDraft, CatalogScope> {
  List<MenuThemePreset> get presets =>
      ref.read(captureConfigProvider).themePresets;

  @override
  AppearanceDraft build(CatalogScope arg) {
    // Seeded from the profile ONCE. Listening instead would overwrite the
    // owner's try-out every time a logo upload elsewhere refreshed the profile.
    final saved = ref.read(businessProfileFor(arg)).valueOrNull?.appearance;
    return AppearanceDraft(
      saved: saved,
      draft: saved ?? const CatalogAppearance(presetId: MenuThemePreset.defaultId),
    );
  }

  /// The first readability rule the draft breaks, or null.
  AppearanceContrastProblem? get problem => appearanceContrastProblem(state.draft, presets);

  bool get canSave => state.isDirty && problem == null && !state.saving;

  /// A new preset starts from ITS colours: an override chosen against one
  /// palette is rarely readable on another, and silently keeping it would
  /// turn a tap on a preset card into a blocked Save.
  void pickPreset(String presetId) {
    // Layout and font are not colours — they survive a change of palette.
    state = state.copyWith(
      draft: CatalogAppearance(
        presetId: presetId,
        layout: state.draft.layout,
        fontId: state.draft.fontId,
        showFilters: state.draft.showFilters,
      ),
      error: null,
    );
  }

  /// Stage 3. `grid` is stored as absent — it is the default.
  void setLayout(MenuLayout layout) {
    state = state.copyWith(
      draft: state.draft.copyWith(layout: layout == MenuLayout.grid ? null : layout),
      error: null,
    );
  }

  /// Stage 5: the diet filter bar on the menu.
  void setShowFilters(bool on) {
    state = state.copyWith(draft: state.draft.copyWith(showFilters: on), error: null);
  }

  /// Stage 3. The default pairing is stored as absent.
  void setFont(String fontId) {
    state = state.copyWith(
      draft: state.draft.copyWith(
        fontId: fontId == MenuThemeFont.defaultId ? null : fontId,
      ),
      error: null,
    );
  }

  /// Null = back to the preset's own colour.
  void setPrimary(String? hex) {
    state = state.copyWith(
      draft: state.draft.copyWith(primary: hex?.toUpperCase()),
      error: null,
    );
  }

  void setAccent(String? hex) {
    state = state.copyWith(
      draft: state.draft.copyWith(accent: hex?.toUpperCase()),
      error: null,
    );
  }

  /// Saves the draft. Returns true on success; a failure stays on [state].
  Future<bool> save() async {
    if (!canSave) return false;
    return _write(AppearanceDraft._normalise(state.draft));
  }

  /// "Reset to default" — clears the saved appearance on the server.
  Future<bool> reset() async {
    if (state.saving) return false;
    return _write(null);
  }

  Future<bool> _write(CatalogAppearance? appearance) async {
    state = state.copyWith(saving: true, error: null);
    try {
      final profile = await ref
          .read(businessProfileFor(arg).notifier)
          .saveAppearance(appearance);
      final saved = profile.appearance;
      state = AppearanceDraft(
        saved: saved,
        draft: saved ?? const CatalogAppearance(presetId: MenuThemePreset.defaultId),
      );
      return true;
    } on CatalogFailure catch (failure) {
      state = state.copyWith(saving: false, error: failure);
      return false;
    }
  }
}

final appearanceFor = NotifierProvider.autoDispose
    .family<AppearanceNotifier, AppearanceDraft, CatalogScope>(AppearanceNotifier.new);
