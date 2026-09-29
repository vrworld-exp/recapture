// test/catalog/catalog_repo_publish_defaults.dart
//
// The publish half of [CatalogRepository], stubbed out for the fakes that do
// not care about it.
//
// Publishing landed on the SAME seam as catalog CRUD and categories (one state
// machine, one owner), which means every pre-existing fake in test/catalog
// suddenly owes five more methods. A mixin rather than five copy-pasted
// `throw UnimplementedError()` blocks per file: the next method added to the
// publish surface is then one edit here instead of one edit per fake, and a
// fake that DOES exercise publishing simply does not use this.
//
// Every stub throws. A test that reaches one is asserting on a call it never
// meant to make, and a silent default (an empty status, a fake run id) would
// let that pass.
import 'package:recapture/domain/catalog/menu_time.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/catalog/publish_status.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';

mixin CatalogRepoPublishDefaults implements CatalogRepository {
  @override
  Future<PublishRequestResult> publish({String? idempotencyKey}) =>
      throw UnimplementedError('publish is not exercised by this test');

  @override
  Future<PublishRequestResult> retryFailedPublish() =>
      throw UnimplementedError('retry is not exercised by this test');

  @override
  Future<PublishStatus> publishStatus() =>
      throw UnimplementedError('publish status is not exercised by this test');

  @override
  Future<UnpublishResult> unpublish() =>
      throw UnimplementedError('unpublish is not exercised by this test');

  @override
  Future<CatalogSubscription> subscription() => throw UnimplementedError(
      'the subscription is not exercised by this test');

  @override
  Future<CatalogQrImage> fetchQr({
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) =>
      throw UnimplementedError('the QR is not exercised by this test');

  @override
  Future<StandeeQuota> fetchStandeeQuota() =>
      throw UnimplementedError('standees are not exercised by this test');

  @override
  Future<StandeeDownload> downloadStandees(int copies) =>
      throw UnimplementedError('standees are not exercised by this test');

  // Stage 4 — in BOTH the publish and delete defaults on purpose: between them
  // they cover every CatalogRepository fake in test/catalog, and a class mixing
  // both takes one identical stub either way.
  @override
  Future<CatalogCategory> setCategorySchedule(
    String id, {
    required CategorySchedule? schedule,
    required bool hideOutsideWindow,
  }) =>
      throw UnimplementedError('category schedule is not exercised by this test');
}
