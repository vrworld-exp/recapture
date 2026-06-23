// lib/application/capture/grid_selection.dart
//
// Platform-AGNOSTIC multi-select state for the Screen 7A review grid. ONE shared
// selection (a Set of photo ids + a mode flag); the two platforms (Android
// Contextual Action Bar, iOS Edit mode) only differ in the entry gesture, chrome,
// and exit — they all drive THIS controller. Pure logic (ChangeNotifier only), so
// it is unit-testable with no widget/platform involved.
//
// Keyed by photo id (ReviewItem.captureId), NEVER by grid index, so reordering or
// deleting items never corrupts the selection.
//
// DESELECT-LAST DIVERGENCE: whether emptying the selection should auto-exit
// selection mode is a PLATFORM convention (Android CAB dismisses; iOS Edit mode
// stays). The controller stays platform-free by taking an [autoExitWhenEmpty]
// flag on the operations that can empty the set — the widget layer, which knows
// the platform, passes `true` on Android and `false` on iOS.
import 'package:flutter/foundation.dart';

class GridSelection extends ChangeNotifier {
  final Set<String> _selected = <String>{};
  bool _isSelectionMode = false;

  /// The currently selected photo ids (unmodifiable snapshot).
  Set<String> get selectedIds => Set<String>.unmodifiable(_selected);

  /// Whether the grid is in selection mode (CAB / Edit mode showing).
  bool get isSelectionMode => _isSelectionMode;

  /// Live count of selected items.
  int get count => _selected.length;

  bool isSelected(String id) => _selected.contains(id);

  /// Enters selection mode, optionally selecting [initialId] (the long-pressed
  /// tile on Android). Idempotent — re-entering with the same id is a no-op.
  void enterSelection([String? initialId]) {
    var changed = false;
    if (!_isSelectionMode) {
      _isSelectionMode = true;
      changed = true;
    }
    if (initialId != null && _selected.add(initialId)) changed = true;
    if (changed) notifyListeners();
  }

  /// Exits selection mode AND clears the selection (the X / BACK / Done / Cancel).
  void exitSelection() {
    if (!_isSelectionMode && _selected.isEmpty) return;
    _isSelectionMode = false;
    _selected.clear();
    notifyListeners();
  }

  /// Toggles [id]'s membership. Adding ensures selection mode is on; removing the
  /// last item auto-exits only when [autoExitWhenEmpty] (Android convention).
  void toggle(String id, {bool autoExitWhenEmpty = false}) {
    if (_selected.remove(id)) {
      if (_selected.isEmpty && autoExitWhenEmpty) _isSelectionMode = false;
    } else {
      _selected.add(id);
      _isSelectionMode = true;
    }
    notifyListeners();
  }

  /// Selects every id in [ids] (and ensures selection mode). No-op effect if all
  /// were already selected, but still notifies for simplicity.
  void selectAll(Iterable<String> ids) {
    _isSelectionMode = true;
    _selected.addAll(ids);
    notifyListeners();
  }

  /// Clears the selection but STAYS in selection mode unless [autoExitWhenEmpty].
  void clear({bool autoExitWhenEmpty = false}) {
    final hadAny = _selected.isNotEmpty;
    _selected.clear();
    if (autoExitWhenEmpty) _isSelectionMode = false;
    if (hadAny || autoExitWhenEmpty) notifyListeners();
  }

  /// Drops any selected id NOT in [presentIds] — call when the item set changes
  /// (e.g. a delete action removed photos) so the selection never references gone
  /// items. Auto-exits when the selection empties only if [autoExitWhenEmpty].
  void retain(Set<String> presentIds, {bool autoExitWhenEmpty = false}) {
    final before = _selected.length;
    _selected.removeWhere((id) => !presentIds.contains(id));
    final changed = _selected.length != before;
    if (changed && _selected.isEmpty && autoExitWhenEmpty) {
      _isSelectionMode = false;
    }
    if (changed) notifyListeners();
  }
}
