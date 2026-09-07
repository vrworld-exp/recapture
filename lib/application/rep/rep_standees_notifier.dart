// lib/application/rep/rep_standees_notifier.dart
//
// The stock one rep is carrying: the codes an admin handed them, and the
// printable sheet for each.
//
// MIRRORS AdminBatchCodesNotifier deliberately — same busy-per-row rule, same
// `failure` kept separate from the list so a refused download leaves the list on
// screen, same QrDeliverer seam for the file. The two surfaces are the same
// screen seen from two sides, and a rep reporting a problem to an admin should
// be describing behaviour the admin recognises.
//
// WHAT IT DOES NOT HAVE is paging. The admin's list is a batch of up to two
// thousand; a rep's is a folder they can physically carry, and the endpoint
// returns it whole.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/qr_standee.dart';
import '../catalog/catalog_qr_service.dart';

@immutable
class RepStandeesState {
  const RepStandeesState({
    this.standees = const AsyncLoading(),
    this.busyCode,
    this.failure,
    this.notice,
  });

  final AsyncValue<List<RepStandee>> standees;

  /// Which code is being rendered, so one row spins rather than the whole list.
  final String? busyCode;

  /// A failed action, held apart from [standees] so a refused download leaves
  /// the list up — the rep's next move is usually a different standee.
  final CatalogFailure? failure;

  final String? notice;

  bool isBusy(String code) => busyCode == code;

  /// The codes a rep can put on a table right now.
  ///
  /// This is what the activation screen offers as recommendations, so the
  /// filter lives HERE rather than in that screen: "usable" must mean the same
  /// thing on the list and in the picker, and [RepStandee.canActivate] is the
  /// one place that decides it.
  List<RepStandee> get available =>
      (standees.valueOrNull ?? const <RepStandee>[])
          .where((s) => s.canActivate)
          .toList(growable: false);

  RepStandeesState copyWith({
    AsyncValue<List<RepStandee>>? standees,
    Object? busyCode = _unset,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      RepStandeesState(
        standees: standees ?? this.standees,
        busyCode:
            identical(busyCode, _unset) ? this.busyCode : busyCode as String?,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class RepStandeesNotifier extends AutoDisposeNotifier<RepStandeesState> {
  bool _disposed = false;

  RepRepository get _repo => ref.read(repRepositoryProvider);

  @override
  RepStandeesState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(load);
    return const RepStandeesState();
  }

  Future<void> load() async {
    try {
      final standees = await _repo.standees();
      if (_disposed) return;
      state = state.copyWith(standees: AsyncData(standees), failure: null);
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      state = state.copyWith(standees: AsyncError(failure, stack));
    }
  }

  /// Fetches one standee's printable sheet and hands it to the platform.
  ///
  /// Same seam and same failure collapse as the admin surface: a dismissed
  /// share sheet and a browser that refused a download both arrive as platform
  /// exceptions whose own text is not fit to show a rep.
  Future<void> deliverStandee(
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
      state =
          state.copyWith(busyCode: null, notice: 'Standee $code saved.');
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(busyCode: null, failure: failure);
    } catch (_) {
      if (_disposed) return;
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

/// The standees assigned to the signed-in rep.
///
/// NOT autoDispose-family — there is one rep per session, and the id comes from
/// the token rather than from a parameter, so there is nothing to key on.
final repStandeesProvider =
    AutoDisposeNotifierProvider<RepStandeesNotifier, RepStandeesState>(
  RepStandeesNotifier.new,
);
