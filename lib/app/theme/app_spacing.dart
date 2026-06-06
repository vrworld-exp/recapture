abstract final class AppSpacing {
  // 4pt grid system
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;

  // Safe-area baseline padding
  static const double screenPadding = 16;
}

abstract final class AppRadius {
  static const double xs = 8; // chips
  static const double sm = 12; // cards, sheets
  static const double md = 16; // primary surfaces
  static const double lg = 24; // hero modals
}

abstract final class AppElevation {
  static const double e0 = 0; // flat
  static const double e1 = 2; // subtle card
  static const double e2 = 6; // sheets / modals
  static const double e3 = 12; // floating controls over camera
}
