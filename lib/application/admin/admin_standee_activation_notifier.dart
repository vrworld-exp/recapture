// lib/application/admin/admin_standee_activation_notifier.dart
//
// State behind `/admin/standees/:batchId/codes/:code/qr` — the restaurant an
// ACTIVE standee turned into, and its QR.
//
// TWO PROVIDERS, ONE SCREEN. [adminStandeeActivationProvider] is the document
// (which restaurant, its link, who activated it) and paints the header, the
// link row and the "Activated by" block. [adminStandeeQrProvider] is the
// square and its save/share, the same shape as the rep's `RepCatalogQrNotifier`
// so the shared [QrCodePanel] drives it with the same callbacks. They are
// separate because they fail separately: a restaurant that is activated but
// not yet published has a document and a 409 for its QR, and the screen
// shows the first while explaining the second.
//
// The activating rep's RAW contact is NOT here. The document carries the
// list-safe summary; the screen's "Activated by" block fetches the detail
// through `projectOwnerProvider` — the one bounded unmasked-contact path —
// on open, and drops it on close, exactly as the "Created by" sheet does.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart';
import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart'
    show CatalogQrFormat, CatalogQrImage;
import '../../domain/entities/standee_activation.dart';
import '../catalog/catalog_qr_notifier.dart' show kCatalogQrSize;
import '../catalog/catalog_qr_service.dart';

/// The activation document, read once per screen open.
final adminStandeeActivationProvider = FutureProvider.autoDispose
    .family<StandeeActivation, String>(
  (ref, code) => ref.read(adminStandeeRepositoryProvider).activation(code),
);

@immutable
class AdminStandeeQrState {
  const AdminStandeeQrState({
    this.image = const AsyncLoading(),
    this.savingFormat,
    this.failure,
    this.notice,
  });

  final AsyncValue<CatalogQrImage> image;
  final CatalogQrFormat? savingFormat;
  final CatalogFailure? failure;
  final String? notice;

  AdminStandeeQrState copyWith({
    AsyncValue<CatalogQrImage>? image,
    Object? savingFormat = _unset,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      AdminStandeeQrState(
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

/// The square for one activated standee's restaurant. A copy of the rep's
/// notifier over the admin repository — the two differ only in the route.
class AdminStandeeQrNotifier
    extends AutoDisposeFamilyNotifier<AdminStandeeQrState, String> {
  bool _disposed = false;

  AdminStandeeRepository get _repo => ref.read(adminStandeeRepositoryProvider);

  @override
  AdminStandeeQrState build(String code) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(load);
    return const AdminStandeeQrState();
  }

  Future<void> load() async {
    try {
      final image = await _repo.activationQr(arg, size: kCatalogQrSize);
      if (_disposed) return;
      state = state.copyWith(image: AsyncData(image), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(image: AsyncError(failure, stack));
    }
  }

  Future<void> save(CatalogQrFormat format) async {
    if (state.savingFormat != null) return;
    state = state.copyWith(savingFormat: format, failure: null, notice: null);

    try {
      final onScreen = state.image.valueOrNull;
      final image = (format == CatalogQrFormat.png && onScreen != null)
          ? onScreen
          : await _repo.activationQr(arg, format: format, size: kCatalogQrSize);
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
      state = state.copyWith(
        savingFormat: null,
        failure: const CatalogFailure(
          code: 'QR_SAVE_FAILED',
          message: "We couldn't save the QR code. Please try again.",
        ),
      );
    }
  }
}

final adminStandeeQrProvider = AutoDisposeNotifierProviderFamily<
    AdminStandeeQrNotifier, AdminStandeeQrState, String>(
  AdminStandeeQrNotifier.new,
);
