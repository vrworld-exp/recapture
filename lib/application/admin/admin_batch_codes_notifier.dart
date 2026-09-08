// lib/application/admin/admin_batch_codes_notifier.dart
//
// One batch's codes, and the two ways a code leaves this screen: as a printable
// standee for ONE code (the pilot path — an admin sends it to a rep, who prints
// a sheet), or as the whole batch's CSV (the vendor path).
//
// Both go out through the SAME [QrDeliverer] seam the catalog QR screen uses —
// share sheet on mobile, blob download in the browser — so this surface needed
// no new platform code and behaves identically on both targets.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart';
import '../../data/repositories/catalog_failure.dart';
import '../../domain/entities/qr_standee.dart';
import '../catalog/catalog_qr_service.dart';

/// How many codes one page holds.
///
/// Matches the backend default. A batch runs to 2,000 by default and 10,000 at
/// the ceiling, so this list is paged rather than fetched whole — an admin
/// looking for a free code needs the first screenful, not the inventory.
const int kStandeePageSize = 100;

@immutable
class AdminBatchCodesState {
  const AdminBatchCodesState({
    this.codes = const AsyncLoading(),
    this.nextAfter,
    this.loadingMore = false,
    this.busyCode,
    this.bulkBusy = false,
    this.downloadingCsv = false,
    this.failure,
    this.notice,
  });

  final AsyncValue<List<QrStandeeCode>> codes;

  /// Keyset cursor for the next page; null at the end of the batch.
  final String? nextAfter;

  final bool loadingMore;

  /// Which code is being rendered right now, so one row spins rather than the
  /// whole list going busy.
  final String? busyCode;

  /// A whole-batch assign or return in flight.
  ///
  /// SEPARATE from [busyCode] because they disable different things. One row
  /// downloading must not grey out the batch action, and a batch-wide change
  /// must not look like one row is busy.
  final bool bulkBusy;

  final bool downloadingCsv;

  /// A failed action. Separate from [codes] so a refused render leaves the list
  /// on screen — the admin's next move is usually to pick a different code.
  final CatalogFailure? failure;

  final String? notice;

  bool get hasMore => nextAfter != null;

  bool isBusy(String code) => busyCode == code;

  AdminBatchCodesState copyWith({
    AsyncValue<List<QrStandeeCode>>? codes,
    Object? nextAfter = _unset,
    bool? loadingMore,
    Object? busyCode = _unset,
    bool? bulkBusy,
    bool? downloadingCsv,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      AdminBatchCodesState(
        codes: codes ?? this.codes,
        nextAfter:
            identical(nextAfter, _unset) ? this.nextAfter : nextAfter as String?,
        loadingMore: loadingMore ?? this.loadingMore,
        busyCode:
            identical(busyCode, _unset) ? this.busyCode : busyCode as String?,
        bulkBusy: bulkBusy ?? this.bulkBusy,
        downloadingCsv: downloadingCsv ?? this.downloadingCsv,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class AdminBatchCodesNotifier
    extends AutoDisposeFamilyNotifier<AdminBatchCodesState, String> {
  bool _disposed = false;

  AdminStandeeRepository get _repo => ref.read(adminStandeeRepositoryProvider);

  @override
  AdminBatchCodesState build(String batchId) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(load);
    return const AdminBatchCodesState();
  }

  Future<void> load() async {
    try {
      final page = await _repo.codes(arg, limit: kStandeePageSize);
      if (_disposed) return;
      state = state.copyWith(
        codes: AsyncData(page.codes),
        nextAfter: page.nextAfter,
        failure: null,
      );
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(codes: AsyncError(failure, stack));
    }
  }

  /// Appends the next page.
  ///
  /// A failure here sets [AdminBatchCodesState.failure] and leaves the pages
  /// already loaded alone: losing a screenful the admin was reading, to report
  /// that the NEXT one did not arrive, would be the wrong trade.
  Future<void> loadMore() async {
    final cursor = state.nextAfter;
    if (cursor == null || state.loadingMore) return;
    state = state.copyWith(loadingMore: true, failure: null);

    try {
      final page =
          await _repo.codes(arg, after: cursor, limit: kStandeePageSize);
      if (_disposed) return;
      state = state.copyWith(
        codes: AsyncData([...state.codes.valueOrNull ?? const [], ...page.codes]),
        nextAfter: page.nextAfter,
        loadingMore: false,
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(loadingMore: false, failure: failure);
    }
  }

  /// Fetches one code's printable standee and hands it to the platform.
  Future<void> deliverStandee(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
  }) async {
    if (state.busyCode != null) return;
    state = state.copyWith(busyCode: code, failure: null, notice: null);

    await _deliver(
      () => _repo.standeeFile(code, format: format),
      onDone: (s) => s.copyWith(busyCode: null, notice: 'Standee $code saved.'),
      onFail: (s, failure) => s.copyWith(busyCode: null, failure: failure),
    );
  }

  /// Hands one standee to one rep.
  ///
  /// THE ROW IS PATCHED IN PLACE from the response, not re-fetched. A reload
  /// would restart the keyset paging from page one and throw away every page
  /// the admin had scrolled through — to learn one field the server just told
  /// us. The response carries the holder precisely so this can be a local edit.
  ///
  /// Reassignment needs no special case: the endpoint overwrites, so handing a
  /// code to a second rep is the same call as the first.
  Future<void> assign(String code, {required String repUserId}) async {
    if (state.busyCode != null) return;
    state = state.copyWith(busyCode: code, failure: null, notice: null);

    try {
      final holder = await _repo.assign(code, repUserId: repUserId);
      if (_disposed) return;
      state = _patchRow(code, holder).copyWith(
        busyCode: null,
        notice: 'Standee $code assigned to ${holder.label}.',
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(busyCode: null, failure: failure);
    }
  }

  /// Takes a standee back off whoever was holding it.
  Future<void> unassign(String code) async {
    if (state.busyCode != null) return;
    state = state.copyWith(busyCode: code, failure: null, notice: null);

    try {
      await _repo.unassign(code);
      if (_disposed) return;
      state = _patchRow(code, null).copyWith(
        busyCode: null,
        notice: 'Standee $code is back in stock.',
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(busyCode: null, failure: failure);
    }
  }

  /// Hands the WHOLE batch to one rep.
  ///
  /// Loaded rows are patched in place and the rest are simply left to arrive
  /// correct: a page fetched after this call comes from a server that already
  /// has the new holder. So there is no reload, and the admin keeps every page
  /// they had scrolled through — the same reasoning as [assign], reached from
  /// the opposite direction.
  ///
  /// RETIRED ROWS ARE SKIPPED HERE TOO, mirroring the endpoint exactly. If the
  /// local patch marked them assigned, the list would disagree with the server
  /// the moment anything refetched, and the count in the confirmation would
  /// disagree with what is on screen right now.
  Future<void> assignAll({required String repUserId}) async {
    if (state.bulkBusy) return;
    state = state.copyWith(bulkBusy: true, failure: null, notice: null);

    try {
      final result = await _repo.assignBatch(arg, repUserId: repUserId);
      if (_disposed) return;
      final holder = result.assignedTo;
      state = _patchAll(holder, skipRetired: true).copyWith(
        bulkBusy: false,
        notice: _bulkNotice(result),
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(bulkBusy: false, failure: failure);
    }
  }

  /// Empties the batch back into stock.
  ///
  /// Clears RETIRED rows as well, matching the endpoint: a stale holder on a
  /// sheet nobody can use is exactly what somebody emptying a batch is tidying
  /// up, and leaving it would make the batch read half-assigned forever.
  Future<void> unassignAll() async {
    if (state.bulkBusy) return;
    state = state.copyWith(bulkBusy: true, failure: null, notice: null);

    try {
      final cleared = await _repo.unassignBatch(arg);
      if (_disposed) return;
      state = _patchAll(null, skipRetired: false).copyWith(
        bulkBusy: false,
        notice: cleared == 0
            ? 'Nobody was holding this batch.'
            : 'Returned $cleared standees to stock.',
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(bulkBusy: false, failure: failure);
    }
  }

  /// The confirmation, which NAMES THE SKIPPED CODES when there were any.
  ///
  /// "Assigned 18" against a batch of 20 reads as a bug; the same sentence
  /// with "2 retired" after it reads as the system working.
  String _bulkNotice(BatchAssignmentResult result) {
    final who = result.assignedTo?.label;
    final head = who == null
        ? 'Assigned ${result.assigned} standees.'
        : 'Assigned ${result.assigned} standees to $who.';
    if (result.skippedRetired == 0) return head;
    return '$head ${result.skippedRetired} retired and were skipped.';
  }

  /// Replaces the holder on every loaded row.
  ///
  /// [skipRetired] keeps this in step with the endpoint, which refuses to put
  /// a retired sheet on anybody list but does clear one.
  AdminBatchCodesState _patchAll(
    StandeeAssignee? holder, {
    required bool skipRetired,
  }) {
    final rows = state.codes.valueOrNull;
    if (rows == null) return state;
    return state.copyWith(
      codes: AsyncData([
        for (final row in rows)
          if (skipRetired && row.state == QrCodeState.retired)
            row
          else
            row.copyWith(assignedTo: holder),
      ]),
    );
  }

  /// Replaces one row's holder, leaving every other row and the paging cursor
  /// untouched.
  ///
  /// A no-op when the list is not loaded, or when the code is not on a page the
  /// admin currently has — neither can happen from the UI (the action starts
  /// from a visible row) and both would be a silent list rewrite if they did.
  AdminBatchCodesState _patchRow(String code, StandeeAssignee? holder) {
    final rows = state.codes.valueOrNull;
    if (rows == null) return state;
    return state.copyWith(
      codes: AsyncData([
        for (final row in rows)
          if (row.code == code) row.copyWith(assignedTo: holder) else row,
      ]),
    );
  }

  /// Fetches the whole batch's vendor CSV and hands it to the platform.
  Future<void> deliverCsv() async {
    if (state.downloadingCsv) return;
    state = state.copyWith(downloadingCsv: true, failure: null, notice: null);

    await _deliver(
      () => _repo.batchCsv(arg),
      onDone: (s) =>
          s.copyWith(downloadingCsv: false, notice: 'Batch CSV saved.'),
      onFail: (s, failure) =>
          s.copyWith(downloadingCsv: false, failure: failure),
    );
  }

  /// Fetch → deliver → settle, with the two failure shapes both surfaces need.
  ///
  /// The bare `catch` is not laziness: a share sheet the user dismissed and a
  /// browser that refused a download both arrive as platform exceptions whose
  /// own text is not fit to show anyone, so they collapse to one mapped
  /// sentence — exactly as `catalog_qr_notifier.dart` does.
  Future<void> _deliver(
    Future<QrDownloadFile> Function() fetch, {
    required AdminBatchCodesState Function(AdminBatchCodesState) onDone,
    required AdminBatchCodesState Function(
      AdminBatchCodesState,
      CatalogFailure,
    ) onFail,
  }) async {
    try {
      final file = await fetch();
      if (_disposed) return;
      await ref.read(qrDelivererProvider).deliver(file);
      if (_disposed) return;
      state = onDone(state);
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = onFail(state, failure);
    } catch (_) {
      if (_disposed) return;
      state = onFail(
        state,
        const CatalogFailure(
          code: 'QR_SAVE_FAILED',
          message: "We couldn't save that file. Please try again.",
        ),
      );
    }
  }

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

/// One batch's codes, keyed by batch id.
final adminBatchCodesProvider = AutoDisposeNotifierProviderFamily<
    AdminBatchCodesNotifier, AdminBatchCodesState, String>(
  AdminBatchCodesNotifier.new,
);
