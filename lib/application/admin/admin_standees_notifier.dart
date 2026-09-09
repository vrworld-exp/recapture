// lib/application/admin/admin_standees_notifier.dart
//
// The admin's standee inventory: every mint run, and the button that makes a
// new one.
//
// WHY THIS SCREEN EXISTS AT ALL. The mint and export endpoints have been in the
// tree since stage 2 with no UI in front of them, on the reasoning that minting
// is a handful of ADMIN actions a year and an unused admin screen is worse than
// none. That reasoning covered the PRINT VENDOR path — hand a CSV to a printer,
// receive standees. It does not cover the pilot: before a vendor is engaged, an
// admin has to be able to get one code to a rep today, and doing that through
// curl means no restaurant can be onboarded without an engineer in the room.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart';
import '../../data/repositories/catalog_failure.dart';
import '../../domain/entities/qr_standee.dart';
import '../catalog/catalog_qr_service.dart';

@immutable
class AdminStandeesState {
  const AdminStandeesState({
    this.batches = const AsyncLoading(),
    this.minting = false,
    this.downloadingSheetFor,
    this.failure,
    this.notice,
  });

  final AsyncValue<List<QrBatchSummary>> batches;

  /// Whether [batchId]'s sheet is being fetched right now.
  bool isDownloadingSheet(String batchId) => downloadingSheetFor == batchId;

  /// A mint in flight. Blocks a second one: a double-tap on this button is a
  /// second physical print run, not a duplicate read.
  final bool minting;

  /// The batch whose printable sheet is being fetched, or null.
  ///
  /// A BATCH ID rather than a bool, so ONE row spins instead of the whole list
  /// going busy — the same instinct as [AdminBatchCodesState.busyCode]. An
  /// admin downloading sheets for two runs in a row must be able to see which
  /// one they are waiting on.
  final String? downloadingSheetFor;

  /// A failed action. Kept apart from [batches] so a mint that fails leaves the
  /// list the admin is looking at intact.
  final CatalogFailure? failure;

  final String? notice;

  AdminStandeesState copyWith({
    AsyncValue<List<QrBatchSummary>>? batches,
    bool? minting,
    Object? downloadingSheetFor = _unset,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      AdminStandeesState(
        batches: batches ?? this.batches,
        minting: minting ?? this.minting,
        downloadingSheetFor: identical(downloadingSheetFor, _unset)
            ? this.downloadingSheetFor
            : downloadingSheetFor as String?,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class AdminStandeesNotifier extends AutoDisposeNotifier<AdminStandeesState> {
  bool _disposed = false;

  AdminStandeeRepository get _repo =>
      ref.read(adminStandeeRepositoryProvider);

  @override
  AdminStandeesState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(load);
    return const AdminStandeesState();
  }

  Future<void> load() async {
    try {
      final batches = await _repo.batches();
      if (_disposed) return;
      state = state.copyWith(batches: AsyncData(batches), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(batches: AsyncError(failure, stack));
    }
  }

  /// Mints a run and reloads the list.
  ///
  /// Returns the new batch's id so the screen can push straight into it — the
  /// admin minted because they want codes NOW, and making them find the run
  /// they just created in a list is a step for no reason.
  Future<String?> mint({
    required int count,
    required String label,
    String? assignToUserId,
  }) async {
    if (state.minting) return null;
    state = state.copyWith(minting: true, failure: null, notice: null);

    try {
      final result = await _repo.mint(
        count: count,
        label: label,
        assignToUserId: assignToUserId,
      );
      if (_disposed) return null;
      await load();
      if (_disposed) return null;
      // NAMES THE HOLDER FROM THE RESPONSE, not from what was asked for.
      // The mint deliberately survives a failed assignment, so "for Ravi"
      // is only said when the server reports it actually happened.
      final holder = result.assignedTo?.label;
      state = state.copyWith(
        minting: false,
        notice: holder == null
            ? 'Minted ${result.minted} standee codes.'
            : 'Minted ${result.minted} standee codes for $holder.',
      );
      return result.batchId;
    } on CatalogFailure catch (failure) {
      if (_disposed) return null;
      state = state.copyWith(minting: false, failure: failure);
      return null;
    }
  }

  /// Fetches one batch's printable sheet and hands it to the platform.
  ///
  /// ON THE LIST ROW, not only inside the batch. Bulk download is the whole
  /// reason this exists: an admin who has just had fifty standees printed wants
  /// the file, not a tour of the run's individual codes. Opening the batch to
  /// find the same button would be a step for no one.
  ///
  /// Goes out through the SAME [QrDeliverer] seam everything else here uses —
  /// share sheet on mobile, blob download in the browser — so this needed no
  /// platform code and behaves identically on both targets.
  Future<void> deliverSheet(String batchId) async {
    if (state.downloadingSheetFor != null) return;
    state = state.copyWith(
      downloadingSheetFor: batchId,
      failure: null,
      notice: null,
    );

    try {
      final sheet = await _repo.batchSheet(batchId);
      if (_disposed) return;
      await ref.read(qrDelivererProvider).deliver(sheet.file);
      if (_disposed) return;
      state = state.copyWith(
        downloadingSheetFor: null,
        notice: _sheetNotice(sheet),
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(downloadingSheetFor: null, failure: failure);
    } catch (_) {
      // A share sheet the user dismissed and a browser that refused a download
      // both arrive as platform exceptions whose own text is not fit to show
      // anyone, so they collapse to one mapped sentence — as every other
      // delivery path in this app does.
      if (_disposed) return;
      state = state.copyWith(
        downloadingSheetFor: null,
        failure: const CatalogFailure(
          code: 'QR_SAVE_FAILED',
          message: "We couldn't save that file. Please try again.",
        ),
      );
    }
  }

  /// NAMES THE SKIPPED CODES when there were any — "48 standees" against a run
  /// of 50 reads as a bug until something says why.
  ///
  /// Degrades to a bare confirmation when the counts did not arrive: they are
  /// response headers, and a proxy that strips them must not turn a good
  /// download into "Saved 0 standees".
  String _sheetNotice(BatchSheetDownload sheet) {
    if (sheet.standees == 0) return 'Printable sheet saved.';
    final pages = sheet.pages == 1 ? '1 page' : '${sheet.pages} pages';
    final head = 'Saved ${sheet.standees} standees over $pages.';
    if (sheet.skippedRetired == 0) return head;
    return '$head ${sheet.skippedRetired} retired and were skipped.';
  }

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

/// The standee inventory screen's state. autoDispose: nothing needs the batch
/// list once the screen closes, and it is stale the moment a code is activated.
final adminStandeesProvider =
    AutoDisposeNotifierProvider<AdminStandeesNotifier, AdminStandeesState>(
  AdminStandeesNotifier.new,
);
