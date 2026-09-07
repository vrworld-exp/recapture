// lib/application/rep/rep_publish_notifier.dart
//
// "Put this menu online", from the rep's side of the table.
//
// A SEPARATE notifier from `repCatalogProductsProvider` on purpose. That one
// owns the pending-model poll loop — the most delicate thing on the rep detail
// screen — and threading a publish action through it would mean touching the
// loop's lifecycle to add a flag it has no use for. This holds one boolean and
// one result, and the two providers never interact.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/catalog/publish_gate.dart';

@immutable
class RepPublishState {
  const RepPublishState({
    this.publishing = false,
    this.outcome,
    this.gates = const [],
    this.failure,
    this.notice,
  });

  final bool publishing;

  /// Set once a publish has been asked for and answered.
  final RepPublishOutcome? outcome;

  /// Why the menu cannot go live yet. Every failing gate, not the first.
  final List<PublishGate> gates;

  final CatalogFailure? failure;
  final String? notice;

  bool get isBlocked => gates.isNotEmpty;

  RepPublishState copyWith({
    bool? publishing,
    Object? outcome = _unset,
    List<PublishGate>? gates,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      RepPublishState(
        publishing: publishing ?? this.publishing,
        outcome: identical(outcome, _unset)
            ? this.outcome
            : outcome as RepPublishOutcome?,
        gates: gates ?? this.gates,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class RepPublishNotifier
    extends AutoDisposeFamilyNotifier<RepPublishState, String> {
  bool _disposed = false;

  @override
  RepPublishState build(String catalogId) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const RepPublishState();
  }

  /// Asks for the menu to go live.
  ///
  /// A publish already running reports the SAME confirmation as a fresh one.
  /// The rep's question is "is this menu going up", and the answer is yes in
  /// both cases — telling them "409, already running" would be reporting our
  /// concurrency control as if it were their problem.
  Future<void> publish() async {
    if (state.publishing) return;
    state = state.copyWith(
      publishing: true,
      failure: null,
      notice: null,
      gates: const [],
    );

    try {
      final result = await ref.read(repRepositoryProvider).publish(arg);
      if (_disposed) return;
      state = state.copyWith(
        publishing: false,
        outcome: result.outcome,
        notice: 'The menu is going live. Scan the standee in a minute.',
      );
    } on RepPublishBlocked catch (blocked) {
      if (_disposed) return;
      // The gate list is the useful half — it names what to fix while the rep
      // is still standing in the restaurant and can fix it.
      state = state.copyWith(
        publishing: false,
        gates: blocked.gates,
        failure: blocked,
      );
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(publishing: false, failure: failure);
    }
  }

  void dismissNotice() =>
      state = state.copyWith(notice: null, failure: null, gates: const []);
}

/// Publish state for one delegated catalog.
final repPublishProvider = AutoDisposeNotifierProviderFamily<RepPublishNotifier,
    RepPublishState, String>(
  RepPublishNotifier.new,
);
