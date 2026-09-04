// lib/domain/entities/product_model_status.dart

/// Does this product have a usable 3D model RIGHT NOW?
///
/// Mirrors the backend's `PRODUCT_MODEL_STATUSES` onto the row the grid
/// renders, so no screen has to join a product to a capture to answer "can this
/// dish launch AR".
///
/// ⚠ THIS IS NOT [ProductType]. `type` is AUTHORED INTENT — what the user meant
/// this product to be — and it does not move. This is the RUNTIME FACT. A
/// `threeD` product whose model is still generating is a real, valid,
/// publishable menu item; it simply has no AR button yet. Gating AR on `type`
/// is the bug this enum exists to prevent.
///
///   [none]       — image-only, or 3D with no linked model.
///   [queued]     — linked to a model that has not started generating.
///   [processing] — the generator is working on it.
///   [ready]      — assets are live. THE ONLY STATE THAT GATES AR.
///   [failed]     — generation failed. The dish stays on the menu in 2D; this
///                  is NOT an error state for the product.
enum ProductModelStatus { none, queued, processing, ready, failed }

extension ProductModelStatusX on ProductModelStatus {
  /// API string value — must match the backend `PRODUCT_MODEL_STATUSES` exactly.
  String get apiValue => switch (this) {
        ProductModelStatus.none => 'NONE',
        ProductModelStatus.queued => 'QUEUED',
        ProductModelStatus.processing => 'PROCESSING',
        ProductModelStatus.ready => 'READY',
        ProductModelStatus.failed => 'FAILED',
      };

  /// Something is still coming. Drives both the badge and the poll loop's stop
  /// condition — the two must agree, so they read the same getter.
  bool get isPending =>
      this == ProductModelStatus.queued || this == ProductModelStatus.processing;

  /// Defensive parse — anything unrecognized (including an ABSENT field from a
  /// backend that predates it) is [none], the strictly least capable value.
  ///
  /// FAIL-CLOSED, the same rule as [UserRole.fromApiValue]: a client one deploy
  /// ahead of the server shows no AR button rather than promising one it cannot
  /// deliver, and a client one deploy BEHIND ignores a status it does not know
  /// rather than crashing the grid.
  static ProductModelStatus fromApiValue(String? value) =>
      switch (value?.toUpperCase()) {
        'QUEUED' => ProductModelStatus.queued,
        'PROCESSING' => ProductModelStatus.processing,
        'READY' => ProductModelStatus.ready,
        'FAILED' => ProductModelStatus.failed,
        _ => ProductModelStatus.none,
      };
}
