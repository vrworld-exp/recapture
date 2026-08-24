// lib/domain/entities/project_source.dart
//
// Where a project's photos came from. Hand-synced with the backend's
// `PROJECT_SOURCE_VALUES` (recapture-api/src/models/Project.ts) — there is no
// shared package, so the two enums are kept in step by contract (AGENTS.md §0.1).
//
// This is a property of the PROJECT, deliberately NOT a ProjectStatus: an
// upload project stays `draft` until it has a model, exactly like a capture
// project does. The client branches on THIS to decide what a card's primary
// action opens.

/// How a project's photos got there.
enum ProjectSource {
  /// The guided in-app capture flow — rings, a capture manifest, an object size
  /// and a capture mode.
  capture,

  /// An artist's hand-picked set, uploaded from the gallery. No rings, no
  /// manifest — which is why server-side photo auto-selection is unavailable on
  /// one and the artist picks 3–4 by hand.
  upload,
}

extension ProjectSourceApi on ProjectSource {
  /// Stable wire value. Must match the backend enum.
  String get apiValue => switch (this) {
        ProjectSource.capture => 'capture',
        ProjectSource.upload => 'upload',
      };

  /// True when this project's photos were uploaded rather than captured.
  bool get isUpload => this == ProjectSource.upload;
}

/// Inverse of [ProjectSourceApi.apiValue].
///
/// Defaults to [ProjectSource.capture] on ANY unknown or missing value — the
/// same defensive-parse stance `ProjectStatusDisplay.fromApiValue` takes. That
/// default is also what makes a row cached before this field existed read
/// correctly instead of crashing the list.
ProjectSource projectSourceFromApi(String? value) {
  for (final source in ProjectSource.values) {
    if (source.apiValue == value) return source;
  }
  return ProjectSource.capture;
}
