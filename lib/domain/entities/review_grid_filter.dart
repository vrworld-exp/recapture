// lib/domain/entities/review_grid_filter.dart
//
// Pure Dart — NO Flutter imports. The filter applied to the Screen 7A review
// grid (Level A). Only two states by design — rejected photos are not reviewable
// here, so there is no "rejected" option.

/// Filter applied to the Screen 7A review grid.
enum ReviewGridFilter {
  /// Shows every accepted photo for the level.
  all,

  /// Shows only accepted photos that ALSO have a matching WarnedPhotoRecord
  /// (same framePath) in the level's ledger.
  warned,
}
