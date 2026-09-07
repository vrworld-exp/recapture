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

@immutable
class AdminStandeesState {
  const AdminStandeesState({
    this.batches = const AsyncLoading(),
    this.minting = false,
    this.failure,
    this.notice,
  });

  final AsyncValue<List<QrBatchSummary>> batches;

  /// A mint in flight. Blocks a second one: a double-tap on this button is a
  /// second physical print run, not a duplicate read.
  final bool minting;

  /// A failed action. Kept apart from [batches] so a mint that fails leaves the
  /// list the admin is looking at intact.
  final CatalogFailure? failure;

  final String? notice;

  AdminStandeesState copyWith({
    AsyncValue<List<QrBatchSummary>>? batches,
    bool? minting,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      AdminStandeesState(
        batches: batches ?? this.batches,
        minting: minting ?? this.minting,
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
  Future<String?> mint({required int count, required String label}) async {
    if (state.minting) return null;
    state = state.copyWith(minting: true, failure: null, notice: null);

    try {
      final result = await _repo.mint(count: count, label: label);
      if (_disposed) return null;
      await load();
      if (_disposed) return null;
      state = state.copyWith(
        minting: false,
        notice: 'Minted ${result.minted} standee codes.',
      );
      return result.batchId;
    } on CatalogFailure catch (failure) {
      if (_disposed) return null;
      state = state.copyWith(minting: false, failure: failure);
      return null;
    }
  }

  void dismissNotice() => state = state.copyWith(notice: null, failure: null);
}

/// The standee inventory screen's state. autoDispose: nothing needs the batch
/// list once the screen closes, and it is stale the moment a code is activated.
final adminStandeesProvider =
    AutoDisposeNotifierProvider<AdminStandeesNotifier, AdminStandeesState>(
  AdminStandeesNotifier.new,
);
