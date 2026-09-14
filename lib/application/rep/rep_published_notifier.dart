// lib/application/rep/rep_published_notifier.dart
//
// "What have I put live" — the rep's own record of the restaurants they signed
// up, and the one rep list that only ever grows.
//
// KEYED SERVER-SIDE ON WHO ACTIVATED EACH CODE, not on delegation. Delegation is
// current access and can be revoked; having put a restaurant online is a fact
// about the past. A history that emptied itself when somebody lost access to a
// territory would be answering a different question from the one the screen asks.
//
// The download reuses the rep's own standee sheet endpoint, so this screen
// needed no new platform code: the same [QrDeliverer] seam behind the catalog QR
// hands over a share sheet on mobile and a blob download in the browser.
//
// AN ADMIN READS THE SAME SCREEN WIDER. For a rep this is "what have I put
// live"; for an admin it is "how much of what we printed is working", which is
// the same list with the scope taken off plus a denominator. It is ONE screen
// because it is one question asked from two heights — and because the rep view
// is what an admin would otherwise have to imagine while reading it.
//
// The WIDENING IS A DIFFERENT ROUTE, not a widened one: `/rep/published` is
// keyed server-side on the caller's own id and stays that way, and the
// cross-rep read is ADMIN-gated at `/admin/standees/published`. A role is
// checked once, here, to decide which repository to ask.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart'
    show AdminStandeeRepository, StandeeQrFormat, adminStandeeRepositoryProvider;
import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/qr_standee.dart';
import '../auth/user_role_notifier.dart';
import '../catalog/catalog_qr_service.dart';

@immutable
class RepPublishedState {
  const RepPublishedState({
    this.page = const AsyncLoading(),
    this.window = PublishedWindow.all,
    this.everyone = false,
    this.busyCode,
    this.failure,
    this.notice,
  });

  final AsyncValue<RepPublishedPage> page;

  /// Whether this list spans EVERY rep (an admin reading) or just the caller.
  ///
  /// Held in state rather than re-read from the role at each use so the copy,
  /// the header and the rows cannot disagree about whose work is on screen
  /// while a role read is in flight.
  final bool everyone;

  /// How far back the list is looking. Client-held because it is a question
  /// about this screen, not about the data.
  final PublishedWindow window;

  /// Which row is fetching its sheet, so one row spins rather than the list.
  final String? busyCode;

  /// A failed download, kept apart from [page] so it never replaces a list the
  /// rep is still reading.
  final CatalogFailure? failure;

  final String? notice;

  List<RepPublishedStandee> get standees =>
      page.valueOrNull?.standees ?? const [];

  /// Every standee this rep has put live, IGNORING the window.
  ///
  /// The number the screen exists to show. It comes from the server rather than
  /// from `standees.length` precisely so that tapping "Last 7 days" does not
  /// appear to delete most of somebody's career.
  int get total => page.valueOrNull?.total ?? 0;

  /// Every standee ever minted, or null when this read carries no denominator
  /// (a rep's own history). The "115" in "2 of 115 menus live".
  int? get generated => page.valueOrNull?.generated;

  /// Whether the header can show a fraction at all. A denominator of zero is
  /// deliberately still a fraction — "0 of 0 menus live" is the truth about a
  /// business that has not minted anything, and hiding it would read as a bug.
  bool get hasFraction => everyone && generated != null;

  bool isBusy(String code) => busyCode == code;

  RepPublishedState copyWith({
    AsyncValue<RepPublishedPage>? page,
    PublishedWindow? window,
    bool? everyone,
    Object? busyCode = _unset,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      RepPublishedState(
        page: page ?? this.page,
        window: window ?? this.window,
        everyone: everyone ?? this.everyone,
        busyCode:
            identical(busyCode, _unset) ? this.busyCode : busyCode as String?,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class RepPublishedNotifier extends AutoDisposeNotifier<RepPublishedState> {
  bool _disposed = false;

  RepRepository get _repo => ref.read(repRepositoryProvider);

  AdminStandeeRepository get _adminRepo =>
      ref.read(adminStandeeRepositoryProvider);

  @override
  RepPublishedState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // WATCHED, not read: a role that resolves after this screen opens (the
    // first paint of a cold start) must widen the list rather than leave an
    // admin looking at their own three restaurants.
    final everyone = ref.watch(isAdminProvider);
    scheduleMicrotask(load);
    return RepPublishedState(everyone: everyone);
  }

  Future<void> load() async {
    try {
      // The role picks the ROUTE. Both answer the same page shape; only the
      // admin one carries `generated` and per-row activators.
      final page = state.everyone
          ? await _adminRepo.publishedStandees(days: state.window.days)
          : await _repo.publishedStandees(days: state.window.days);
      if (_disposed) return;
      state = state.copyWith(page: AsyncData(page), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(page: AsyncError(failure, stack));
    }
  }

  /// Switches the window and refetches.
  ///
  /// THE OLD ROWS STAY ON SCREEN while the new ones arrive — no AsyncLoading.
  /// Dropping to a spinner on every filter tap makes a list that is usually
  /// small flash for no reason, and the count above it is the thing that does
  /// not change anyway.
  Future<void> setWindow(PublishedWindow window) async {
    if (window == state.window) return;
    state = state.copyWith(window: window, failure: null, notice: null);
    await load();
  }

  /// Fetches one row's printable sheet and hands it to the platform.
  Future<void> deliverSheet(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
  }) async {
    if (state.busyCode != null) return;
    state = state.copyWith(busyCode: code, failure: null, notice: null);

    try {
      final file = await _repo.standeeFile(code, format: format);
      if (_disposed) return;
      await ref.read(qrDelivererProvider).deliver(file);
      if (_disposed) return;
      state = state.copyWith(busyCode: null, notice: 'Standee $code saved.');
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(busyCode: null, failure: failure);
    } catch (_) {
      if (_disposed) return;
      // A dismissed share sheet or a refused browser download. Mapped copy
      // only — a platform exception's own text is not for a user.
      state = state.copyWith(
        busyCode: null,
        failure: const CatalogFailure(
          code: 'QR_SAVE_FAILED',
          message: "We couldn't save that file. Please try again.",
        ),
      );
    }
  }

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

/// The rep's published history. autoDispose so it refetches on open — a
/// restaurant published since the last look should simply be there.
final repPublishedProvider =
    AutoDisposeNotifierProvider<RepPublishedNotifier, RepPublishedState>(
  RepPublishedNotifier.new,
);
