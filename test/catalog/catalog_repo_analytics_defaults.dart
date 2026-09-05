// test/catalog/catalog_repo_analytics_defaults.dart
//
// The analytics half of [CatalogRepository], stubbed out for the fakes that do
// not care about it.
//
// Same reasoning as `catalog_repo_publish_defaults.dart`, and a SECOND mixin
// rather than three more methods on that one: publish and analytics are
// different surfaces, and a fake that exercises one almost never exercises the
// other. Keeping them apart means the analytics fake can take the publish
// defaults and vice versa, instead of one file having to opt out of half of a
// combined mixin.
//
// Every stub throws. A test that reaches one is asserting on a call it never
// meant to make, and a silent default — an empty summary, a zeroed report —
// would let that pass while quietly testing nothing.
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/catalog_analytics.dart';

mixin CatalogRepoAnalyticsDefaults implements CatalogRepository {
  @override
  Future<AnalyticsSummary> fetchAnalyticsSummary({String? from, String? to}) =>
      throw UnimplementedError(
        'the analytics summary is not exercised by this test',
      );

  @override
  Future<AnalyticsTimeseries> fetchAnalyticsTimeseries({
    String? from,
    String? to,
  }) =>
      throw UnimplementedError(
        'the analytics timeseries is not exercised by this test',
      );

  @override
  Future<TopProducts> fetchAnalyticsTopProducts({
    String? from,
    String? to,
    int? limit,
  }) =>
      throw UnimplementedError(
        'analytics top products are not exercised by this test',
      );
}
