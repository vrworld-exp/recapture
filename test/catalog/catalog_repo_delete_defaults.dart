// test/catalog/catalog_repo_delete_defaults.dart
//
// `CatalogRepository.delete` stubbed out for the fakes that do not care about
// it.
//
// Same reasoning as [CatalogRepoPublishDefaults], and the same trade: deleting
// the catalog landed on the catalog-root seam next to fetch/create/update, so
// every pre-existing fake in test/catalog suddenly owes one more method. One
// edit here beats one `throw UnimplementedError()` per fake, and a fake that
// DOES exercise the delete simply overrides it.
//
// It throws rather than returning an empty summary. A test that reaches this is
// asserting on a call it never meant to make, and a silent zero-count success
// would let that pass — while also being the exact shape a real bug takes.
import 'package:recapture/data/repositories/catalog_repository.dart';

mixin CatalogRepoDeleteDefaults implements CatalogRepository {
  @override
  Future<CatalogDeletionSummary> delete() =>
      throw UnimplementedError('catalog delete is not exercised by this test');
}
