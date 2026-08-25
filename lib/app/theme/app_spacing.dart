// lib/app/theme/app_spacing.dart

/// 4pt grid spacing system for ReCapture.
///
/// RULE: All padding, margin, and gap values in the app must reference
/// AppSpacing.* — never use raw double literals for spacing.
abstract final class AppSpacing {
  static const double xs = 4; // tight internal padding, icon gaps
  static const double sm = 8; // small gaps between elements
  static const double md = 12; // medium component padding
  static const double lg = 16; // standard card / screen padding
  static const double xl = 20; // generous component spacing
  static const double xxl = 24; // section spacing
  static const double xxxl = 32; // large section separation
  static const double huge = 40; // hero/splash spacing

  /// Baseline horizontal padding for all full-bleed screens.
  static const double screenPadding = 16;

  /// Baseline vertical padding for safe-area content.
  static const double screenPaddingV = 16;
}

/// Corner radius constants — sourced from PRD design tokens.
///
/// RULE: All BorderRadius values must reference AppRadius.* — never
/// use raw double literals for corner radii.
abstract final class AppRadius {
  static const double xs = 8; // chips, small badges, tags
  static const double sm = 12; // cards, bottom sheets, list tiles
  static const double md = 16; // primary surface containers
  static const double lg = 24; // hero modals, full-screen sheets
}

/// Elevation constants — maps to Material 3 elevation levels.
///
/// Use platform-native shadow rendering:
/// - Android: Material elevation (shadow)
/// - iOS: shadow + blur effect
abstract final class AppElevation {
  static const double e0 = 0; // flat — no shadow (default surface)
  static const double e1 = 2; // subtle card shadow
  static const double e2 = 6; // sheets and modals
  static const double e3 = 12; // floating controls over camera feed
}
