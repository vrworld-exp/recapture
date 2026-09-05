// lib/application/catalog/catalog_qr_notifier.dart
//
// The catalog's QR code (features 31-35).
//
// The image is fetched ONCE at a print-worthy size and reused for both the
// on-screen render and the PNG download. That is deliberate: the endpoint is
// rate-limited, the bytes are a pure function of a URL that never changes, and
// re-fetching for the download would spend a request to get back a file the
// screen is already showing. The PDF is a different render, so it is fetched
// when asked for.
//
// The URL itself is NEVER composed here. It is minted server-side at
// provisioning and frozen (feature 32) — every printed sticker resolves through
// it — so this notifier reads it off the catalog and passes it around verbatim.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';
import 'catalog_qr_service.dart';

/// The size the QR is rendered at.
///
/// Big enough to print: a table sticker is scanned in bad light by whatever
/// phone the customer has, and a QR resampled up from a screen-sized render is
/// exactly the one that will not scan. The server clamps this to its own
/// bounds, so asking large is safe.
const int kCatalogQrSize = 1024;

@immutable
class CatalogQrState {
  const CatalogQrState({
    this.image = const AsyncLoading(),
    this.savingFormat,
    this.failure,
    this.notice,
  });

  /// The PNG the screen draws.
  final AsyncValue<CatalogQrImage> image;

  /// Which format is currently being saved, if any. Held per format so the PDF
  /// button can spin without the PNG button also going busy.
  final CatalogQrFormat? savingFormat;

  /// A failed save. Kept separate from [image] — a download that fails must not
  /// replace a QR the user can still scan off the screen.
  final CatalogFailure? failure;

  /// "Link copied", "Saved" — the confirmation the action needs to be visible.
  final String? notice;

  bool isSaving(CatalogQrFormat format) => savingFormat == format;

  CatalogQrState copyWith({
    AsyncValue<CatalogQrImage>? image,
    Object? savingFormat = _unset,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      CatalogQrState(
        image: image ?? this.image,
        savingFormat: identical(savingFormat, _unset)
            ? this.savingFormat
            : savingFormat as CatalogQrFormat?,
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
      final image = await _repo.fetchQr(size: kCatalogQrSize);
      if (_disposed) return;
      state = state.copyWith(image: AsyncData(image), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(image: AsyncError(failure, stack));
    }
  }

  /// Saves the QR in [format] — a share sheet on mobile, a browser download on
  /// web, chosen by the [qrDelivererProvider] seam.
  ///
  /// The PNG reuses the bytes already on screen; the PDF is a separate render
  /// and is fetched.
  Future<void> save(CatalogQrFormat format) async {
    if (state.savingFormat != null) return;
    state = state.copyWith(savingFormat: format, failure: null, notice: null);

    try {
      final onScreen = state.image.valueOrNull;
      final image = (format == CatalogQrFormat.png && onScreen != null)
          ? onScreen
          : await _repo.fetchQr(format: format, size: kCatalogQrSize);
      if (_disposed) return;

      await ref.read(qrDelivererProvider).deliver(QrDownloadFile(
            bytes: image.bytes,
            fileName: image.fileName,
            mimeType: image.contentType,
          ));
      if (_disposed) return;
      state = state.copyWith(savingFormat: null, notice: 'QR code saved.');
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(savingFormat: null, failure: failure);
    } catch (_) {
      if (_disposed) return;
      // A share sheet the user dismissed, a browser that refused the download.
      // Mapped copy only — a platform exception's own text is not for a user.
      state = state.copyWith(
        savingFormat: null,
        failure: const CatalogFailure(
          code: 'QR_SAVE_FAILED',
          message: "We couldn't save the QR code. Please try again.",
        ),
      );
    }
  }

  void showNotice(String message) => state = state.copyWith(notice: message);

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

/// The QR screen's state. autoDispose so the bytes are not held for the life of
/// the session — a 1024 px PNG is not large, but nothing needs it after the
/// screen closes.
final catalogQrProvider =
    AutoDisposeNotifierProvider<CatalogQrNotifier, CatalogQrState>(
  CatalogQrNotifier.new,
);
