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
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/catalog/publish_status.dart';

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
  Future<CatalogQrImage> fetchQr({
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) =>
      throw UnimplementedError('the QR is not exercised by this test');
}
