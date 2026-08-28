// lib/application/catalog/business_profile_notifier.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/business_profile_repository.dart';
import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/business_profile.dart';
import '../auth/auth_notifier.dart';
import 'catalog_notifier.dart';

/// Where a branding upload has got to.
///
/// The two steps are separate because they FAIL separately, and the difference
/// is the whole reason this enum exists: a commit that fails after the bytes are
/// already in S3 must be retryable without re-uploading them. Collapsing this
/// into one boolean is how a user on a slow connection is made to send a 4 MiB
/// logo twice.
enum BrandingUploadStep {
  idle,

  /// Bytes are on their way to the server.
  uploading,

  /// The bytes have landed; the pointer has not flipped yet.
  committing,
}

/// One branding slot's in-flight upload.
@immutable
class BrandingUpload {
  const BrandingUpload({
    this.step = BrandingUploadStep.idle,
    this.pendingKey,
    this.error,
  });

  final BrandingUploadStep step;

  /// The key the bytes landed on, held ONLY while a commit is outstanding.
  ///
  /// Non-null with [step] idle means exactly one thing: the upload worked and
  /// the commit did not. That is the state a retry must be able to see, because
  /// the retry it wants is the commit alone.
  final String? pendingKey;

  final CatalogFailure? error;

  bool get isBusy => step != BrandingUploadStep.idle;

  /// The upload succeeded but the commit did not — retry the commit, not the
  /// upload.
  bool get canRetryCommit => !isBusy && pendingKey != null;

  BrandingUpload copyWith({
    BrandingUploadStep? step,
    Object? pendingKey = _unset,
    Object? error = _unset,
  }) =>
      BrandingUpload(
        step: step ?? this.step,
        pendingKey: identical(pendingKey, _unset)
            ? this.pendingKey
            : pendingKey as String?,
        error: identical(error, _unset) ? this.error : error as CatalogFailure?,
      );
}

const Object _unset = Object();

/// Owns the business profile (features 58, 59, 60, 2).
///
/// State is an `AsyncValue<BusinessProfile?>` with the same three-way meaning as
/// [CatalogNotifier]: `AsyncData(null)` is **no catalog yet**, which is a
/// first-run state and not an error — the repository translates the server's
/// 404 into it.
///
/// Invariants:
///   - No HTTP here; everything goes through the two repositories.
///   - Nothing on this screen reaches customers. Every write is a draft edit and
///     bumps `draftRevision` server-side, which is why every successful write
///     refreshes [catalogProvider] — the "Draft changes not yet live" badge is
///     server-derived and must never be guessed at locally.
///   - The upload steps live OUTSIDE the AsyncValue, in [uploadOf]. An
///     `AsyncLoading` mid-upload would blank the very form being edited.
class BusinessProfileNotifier extends AsyncNotifier<BusinessProfile?> {
  BusinessProfileRepository get _repo =>
      ref.read(businessProfileRepositoryProvider);

  CatalogRepository get _catalogRepo => ref.read(catalogRepositoryProvider);

  final Map<BrandingSlot, ValueNotifier<BrandingUpload>> _uploads = {
    for (final slot in BrandingSlot.values)
      slot: ValueNotifier<BrandingUpload>(const BrandingUpload()),
  };

  bool _disposed = false;

  /// The upload state for one slot. Listen to it rather than to this notifier:
  /// progress must repaint the slot, not the form.
  ValueNotifier<BrandingUpload> uploadOf(BrandingSlot slot) => _uploads[slot]!;

  @override
  Future<BusinessProfile?> build() async {
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next is AuthUnauthenticated) {
        state = const AsyncData<BusinessProfile?>(null);
      }
    });

    ref.onDispose(() {
      _disposed = true;
      for (final upload in _uploads.values) {
        upload.dispose();
      }
    });

    return _repo.fetch();
  }

  /// Re-reads the profile without emitting `AsyncLoading`, so the form does not
  /// flash a spinner over fields the user is looking at.
  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.fetch());
    } catch (error, stack) {
      // A failed background refresh must not blank a profile that is on screen.
      if (state.valueOrNull == null) state = AsyncError(error, stack);
    }
  }

  /// Saves the profile (feature 60).
  ///
  /// [contact] REPLACES the whole contact block, which is the server's own
  /// semantics — so callers pass the FULL block built from every field, never a
  /// delta. That is also what makes "clear my website" expressible at all.
  ///
  /// Not optimistic: the response is the server's own row, and adopting it is
  /// what keeps `publicFields` and `updatedAt` honest. Throws [CatalogFailure],
  /// which the screen shows beside the form rather than replacing it.
  Future<BusinessProfile> save({
    required String name,
    String? businessName,
    required BusinessContact contact,
  }) async {
    final updated = await _repo.update(
      name: name,
      // The PATCH schema is `.strict()` and refuses null, so an absent business
      // name has to be an absent KEY. An empty string is a legitimate value the
      // server accepts (`max(120)` with no `min`), and it is how the field is
      // cleared.
      businessName: businessName ?? '',
      contact: contact,
    );
    if (!_disposed) state = AsyncData(updated);
    _refreshCatalog();
    return updated;
  }

  /// Uploads a logo or cover and binds it (feature 2).
  ///
  /// Two steps, reported separately, and the SECOND is the one worth retrying on
  /// its own: [BrandingUpload.pendingKey] survives a failed commit so
  /// [retryCommit] never re-sends the bytes.
  ///
  /// Returns true when the image is bound. Never throws — the failure is put on
  /// the slot's own [BrandingUpload] so it renders next to the image it is
  /// about, not as a snackbar over a form.
  Future<bool> uploadBranding(
    BrandingSlot slot,
    Uint8List bytes, {
    required String contentType,
  }) async {
    final upload = _uploads[slot]!;
    upload.value = const BrandingUpload(step: BrandingUploadStep.uploading);

    final String key;
    try {
      key = await _catalogRepo.uploadBrandingBytes(
        bytes,
        slot: slot,
        contentType: contentType,
      );
    } on CatalogFailure catch (failure) {
      upload.value = BrandingUpload(error: failure);
      return false;
    }

    return _commit(slot, key);
  }

  /// Retries a commit whose upload already succeeded. No-op when there is
  /// nothing pending.
  Future<bool> retryCommit(BrandingSlot slot) async {
    final pending = _uploads[slot]!.value.pendingKey;
    if (pending == null) return false;
    return _commit(slot, pending);
  }

  Future<bool> _commit(BrandingSlot slot, String key) async {
    final upload = _uploads[slot]!;
    upload.value = BrandingUpload(
      step: BrandingUploadStep.committing,
      pendingKey: key,
    );

    try {
      final profile = await _catalogRepo.commitBranding(slot: slot, key: key);
      if (_disposed) return true;
      state = AsyncData(profile);
      // Cleared only now: with the pointer flipped there is nothing left to
      // retry, and a stale key here would offer a retry that re-commits an
      // image the user has since replaced.
      upload.value = const BrandingUpload();
      _refreshCatalog();
      return true;
    } on CatalogFailure catch (failure) {
      if (_disposed) return false;
      // The KEY is kept. The bytes are in the bucket; only the pointer failed.
      upload.value = BrandingUpload(pendingKey: key, error: failure);
      return false;
    }
  }

  /// Every write here bumps `draftRevision` server-side, so the catalog's
  /// "Draft changes not yet live" badge and its header name both move.
  ///
  /// Best-effort: the write already succeeded, and a failed refresh must not be
  /// reported as though the save failed.
  void _refreshCatalog() {
    if (_disposed) return;
    unawaited(ref.read(catalogProvider.notifier).refresh().catchError((_) {}));
  }
}

/// The app-wide business profile.
final businessProfileProvider =
    AsyncNotifierProvider<BusinessProfileNotifier, BusinessProfile?>(
  BusinessProfileNotifier.new,
);
