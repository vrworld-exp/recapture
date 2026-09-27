// lib/application/catalog/catalog_qr_notifier.dart
//
// The catalog's QR code (features 31-35), as the OWNER sees it.
//
// VIEW-ONLY. The owner's print file is the counted standee download
// (`owner_standee_notifier.dart`), drawn from the plan's allowance; a free
// PNG/PDF save here would be the way round it, so there is none, and the
// server refuses `/catalog/qr?format=pdf` for the same reason. What this
// fetches is a DISPLAY render — see [kOwnerQrFetchSize].
//
// The URL itself is NEVER composed here. It is minted server-side at
// provisioning and frozen (feature 32) — every printed sticker resolves through
// it — so this notifier reads it off the catalog and passes it around verbatim.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';

/// The size the rep's and admin's QR are rendered at.
///
/// Big enough to print: a table sticker is scanned in bad light by whatever
/// phone the customer has, and a QR resampled up from a screen-sized render is
/// exactly the one that will not scan. The server clamps this to its own
/// bounds, so asking large is safe.
const int kCatalogQrSize = 1024;

/// The owner's on-screen render: sharp at the view size on a 3x display, and
/// no bigger — the owner prints through the standee download, not from this.
const int kOwnerQrFetchSize = 512;

@immutable
class CatalogQrState {
  const CatalogQrState({
    this.image = const AsyncLoading(),
    this.failure,
    this.notice,
  });

  /// The PNG the screen draws.
  final AsyncValue<CatalogQrImage> image;

  /// A failed action on the screen. Kept separate from [image] — it must not
  /// replace a QR the user can still scan off the screen.
  final CatalogFailure? failure;

  /// "Link copied" — the confirmation the action needs to be visible.
  final String? notice;

  CatalogQrState copyWith({
    AsyncValue<CatalogQrImage>? image,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      CatalogQrState(
        image: image ?? this.image,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class CatalogQrNotifier extends AutoDisposeNotifier<CatalogQrState> {
  bool _disposed = false;

  CatalogRepository get _repo => ref.read(catalogRepositoryProvider);

  @override
  CatalogQrState build() {
    // Reset first — Riverpod reuses the notifier instance across a rebuild.
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(load);
    return const CatalogQrState();
  }

  /// Fetches the PNG the screen draws.
  ///
  /// A `CATALOG_NOT_PUBLISHED` failure is NOT special-cased away: it is the
  /// honest state before the first publish, and the screen renders its own
  /// explanation off the code.
  Future<void> load() async {
    try {
      final image = await _repo.fetchQr(size: kOwnerQrFetchSize);
      if (_disposed) return;
      state = state.copyWith(image: AsyncData(image), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(image: AsyncError(failure, stack));
    }
  }

  void showNotice(String message) => state = state.copyWith(notice: message);

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

/// The QR screen's state. autoDispose so the bytes are not held for the life of
/// the session.
final catalogQrProvider =
    AutoDisposeNotifierProvider<CatalogQrNotifier, CatalogQrState>(
  CatalogQrNotifier.new,
);
