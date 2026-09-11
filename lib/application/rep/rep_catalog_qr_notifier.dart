// lib/application/rep/rep_catalog_qr_notifier.dart
//
// One delegated restaurant's QR code — the square a rep shows, saves and hands
// over before leaving the table.
//
// A FAMILY, keyed on the catalog id, because a rep holds several restaurants at
// once and the owner's [CatalogQrNotifier] holds exactly one. That is the whole
// difference between the two: same fetch-once-and-reuse rule, same two save
// formats, same refusal to compose a URL — the id is the only thing this one
// has to carry that the owner's does not.
//
// autoDispose so the bytes are not held for the life of the session. A rep who
// opens four restaurants in an afternoon should not be carrying four print-sized
// PNGs around in memory afterwards.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart'
    show CatalogQrFormat, CatalogQrImage;
import '../../data/repositories/rep_repository.dart';
import '../catalog/catalog_qr_notifier.dart' show kCatalogQrSize;
import '../catalog/catalog_qr_service.dart';

@immutable
class RepCatalogQrState {
  const RepCatalogQrState({
    this.image = const AsyncLoading(),
    this.savingFormat,
    this.failure,
    this.notice,
  });

  /// The PNG the screen draws.
  final AsyncValue<CatalogQrImage> image;

  /// Which format is being saved, held per format so the PDF button can spin
  /// without the PNG button also going busy.
  final CatalogQrFormat? savingFormat;

  /// A failed save. Kept apart from [image] — a download that fails must not
  /// replace a QR the restaurant can still scan off the rep's screen.
  final CatalogFailure? failure;

  final String? notice;

  RepCatalogQrState copyWith({
    AsyncValue<CatalogQrImage>? image,
    Object? savingFormat = _unset,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      RepCatalogQrState(
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

class RepCatalogQrNotifier
    extends AutoDisposeFamilyNotifier<RepCatalogQrState, String> {
  bool _disposed = false;

  RepRepository get _repo => ref.read(repRepositoryProvider);

  @override
  RepCatalogQrState build(String catalogId) {
    // Reset first — Riverpod reuses the notifier instance across a rebuild.
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(load);
    return const RepCatalogQrState();
  }

  /// Fetches the PNG the screen draws.
  ///
  /// A `CATALOG_NOT_PUBLISHED` failure is NOT special-cased away: it is the
  /// honest state before the restaurant's first publish, and the screen renders
  /// its own explanation off the code.
  Future<void> load() async {
    try {
      final image = await _repo.catalogQr(arg, size: kCatalogQrSize);
      if (_disposed) return;
      state = state.copyWith(image: AsyncData(image), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(image: AsyncError(failure, stack));
    }
  }

  /// Saves the QR in [format] — a share sheet on mobile, a browser download on
  /// web, chosen by the [qrDelivererProvider] seam the owner's QR uses.
  ///
  /// The PNG reuses the bytes already on screen; the PDF is a separate render
  /// server-side and so is fetched.
  Future<void> save(CatalogQrFormat format) async {
    if (state.savingFormat != null) return;
    state = state.copyWith(savingFormat: format, failure: null, notice: null);

    try {
      final onScreen = state.image.valueOrNull;
      final image = (format == CatalogQrFormat.png && onScreen != null)
          ? onScreen
          : await _repo.catalogQr(arg, format: format, size: kCatalogQrSize);
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
      // A share sheet the rep dismissed, a browser that refused the download.
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

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

final repCatalogQrProvider = AutoDisposeNotifierProviderFamily<
    RepCatalogQrNotifier, RepCatalogQrState, String>(
  RepCatalogQrNotifier.new,
);
