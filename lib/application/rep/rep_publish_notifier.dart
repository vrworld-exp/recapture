// lib/application/rep/rep_publish_notifier.dart
//
// The REP's door onto the publish flow — one delegated restaurant, published
// on its owner's behalf.
//
// WHAT THIS REPLACED. The rep used to have a publish notifier of its own: a
// button on the dish list, a toast when the request was accepted, a poll of
// the catalog document until `isPublishing` dropped, and nothing else — no
// progress, no per-dish failure, no retry, and a run that failed looked exactly
// like one that finished. The owner had a whole screen for the same run. That
// gap was the literal truth of "restaurant publishing does not work as well as
// catalog publishing", and closing it by copying the owner's screen would have
// left two implementations to drift apart again.
//
// So the rep now runs the SAME flow ([PublishFlow]) behind the same screen
// body, and this file is only what is genuinely the rep's: where the requests
// go (`/rep/catalogs/:id/publish*`, resolved through the delegation grant),
// which document to re-read on a status read (the delegated catalog's, keyed
// by id — never the owner provider, see `rep_draft_badge_test.dart`), and the
// one thing a rep may NOT do, which is take the page offline.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/rep_repository.dart';
import '../../domain/catalog/publish_request_result.dart';
import '../../domain/catalog/publish_status.dart';
import '../catalog/publish_flow.dart';
import 'rep_restaurant_notifier.dart';

/// The rep's [PublishGateway] for one delegated catalog.
class _RepPublishGateway implements PublishGateway {
  _RepPublishGateway(this._ref, this.catalogId);

  final Ref _ref;
  final String catalogId;

  RepRepository get _repo => _ref.read(repRepositoryProvider);

  @override
  Future<PublishStatus> status() => _repo.publishStatus(catalogId);

  @override
  Future<PublishRequestResult> publish({String? idempotencyKey}) =>
      _repo.publish(catalogId, idempotencyKey: idempotencyKey);

  @override
  Future<PublishRequestResult> retryFailed() =>
      _repo.retryFailedPublish(catalogId);

  /// A customer page going dark is the OWNER's decision. The rep's router has
  /// no unpublish route, and this is what keeps the screen from offering one.
  @override
  bool get canUnpublish => false;

  @override
  Future<UnpublishResult> unpublish() =>
      throw UnsupportedError('a rep cannot take a restaurant offline');

  /// The restaurant's name lives on its profile, and the rep may edit it —
  /// the same PATCH the restaurant-details screen makes.
  @override
  Future<void> rename(String name) =>
      _repo.updateProfile(catalogId, name: name);

  /// The dish list's publish bar reads the DELEGATED document. Invalidating
  /// rather than refreshing: the provider is autoDispose, and a bar that is
  /// not on screen should not be re-fetched on its behalf.
  @override
  void onStatusRead() {
    _ref.invalidate(repCatalogDocumentProvider(catalogId));
  }
}

class RepPublishNotifier
    extends AutoDisposeFamilyNotifier<PublishScreenState, String>
    with PublishFlowHost {
  // Not `late final`, for the reason the owner's notifier gives.
  late PublishFlow _flow;

  @override
  PublishFlow get flow => _flow;

  @override
  PublishScreenState build(String catalogId) {
    _flow = PublishFlow(
      gateway: _RepPublishGateway(ref, catalogId),
      read: () => state,
      emit: (next) => state = next,
    );
    ref.onDispose(_flow.dispose);
    return _flow.start();
  }
}

/// The rep's publish screen state for one delegated catalog.
///
/// autoDispose for the same load-bearing reason as the owner's: the poll loop
/// must die with the screen.
final repPublishProvider = AutoDisposeNotifierProviderFamily<RepPublishNotifier,
    PublishScreenState, String>(
  RepPublishNotifier.new,
);
