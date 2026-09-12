// lib/application/catalog/publish_notifier.dart
//
// The OWNER's door onto the publish flow (features 36-39, 52, 53, 68, 69).
//
// Everything that used to live here — the poll loop, the backoff, the
// lifecycle pausing, the act-then-re-read discipline — is now [PublishFlow]
// (publish_flow.dart), shared with the rep's door. This file is what is
// genuinely the owner's: where the requests go (`/catalog/publish*`, resolved
// from their own token), which notifier's catalog is refreshed on a status
// read, and the fact that an owner MAY take their page offline.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_repository.dart';
import '../../domain/catalog/publish_request_result.dart';
import '../../domain/catalog/publish_status.dart';
import 'catalog_notifier.dart';
import 'publish_flow.dart';

export 'publish_flow.dart' show PublishScreenState;

/// The owner's [PublishGateway]: their own catalog, their own routes.
class _OwnerPublishGateway implements PublishGateway {
  _OwnerPublishGateway(this._ref);

  final Ref _ref;

  CatalogRepository get _repo => _ref.read(catalogRepositoryProvider);

  @override
  Future<PublishStatus> status() => _repo.publishStatus();

  @override
  Future<PublishRequestResult> publish({String? idempotencyKey}) =>
      _repo.publish(idempotencyKey: idempotencyKey);

  @override
  Future<PublishRequestResult> retryFailed() => _repo.retryFailedPublish();

  @override
  bool get canUnpublish => true;

  @override
  Future<UnpublishResult> unpublish() => _repo.unpublish();

  @override
  Future<void> rename(String name) =>
      _ref.read(catalogProvider.notifier).updateMetadata(name: name);

  /// The catalog header's own chips (Published / Draft changes / Publishing)
  /// read the catalog notifier, not this one. Best-effort: a failed refresh
  /// must never look like a failed publish.
  @override
  void onStatusRead() {
    unawaited(
      _ref.read(catalogProvider.notifier).refresh().catchError((_) {}),
    );
  }
}

class PublishNotifier extends AutoDisposeNotifier<PublishScreenState>
    with PublishFlowHost {
  // Not `late final`: Riverpod reuses the notifier INSTANCE across a rebuild,
  // and each build owns a fresh flow (the previous one was disposed with the
  // previous element).
  late PublishFlow _flow;

  @override
  PublishFlow get flow => _flow;

  @override
  PublishScreenState build() {
    _flow = PublishFlow(
      gateway: _OwnerPublishGateway(ref),
      read: () => state,
      emit: (next) => state = next,
    );
    ref.onDispose(_flow.dispose);
    return _flow.start();
  }
}

/// The publish screen's state.
///
/// autoDispose is LOAD-BEARING, not tidiness: it is what guarantees the poll
/// loop dies with the screen. A kept-alive provider would keep timing, keep
/// requesting and keep a phone's radio busy for a run nobody is watching.
final publishProvider =
    AutoDisposeNotifierProvider<PublishNotifier, PublishScreenState>(
  PublishNotifier.new,
);
