// lib/app/app_info.dart
//
// Build identity shown to the user (the Profile screen's footer line).
//
// HAND-SYNCED with `version:` in pubspec.yaml — the same hand-sync convention the
// repo already uses for shared shapes across the two codebases (AGENTS.md §0).
// Deliberately NOT read from package_info_plus: that would add a dependency and a
// platform channel for one cosmetic string, and the channel is unavailable in
// widget tests (every screen test would need a mock handler).
//
// When you bump pubspec's `version:`, bump these two constants in the same change.
abstract final class AppInfo {
  /// Semantic version — pubspec `version:` before the `+`.
  static const String version = '1.0.0';

  /// Build number — pubspec `version:` after the `+`.
  static const String buildNumber = '1';

  /// The user-facing line: `Version 1.0.0 (1)`.
  static const String displayVersion = 'Version $version ($buildNumber)';
}
