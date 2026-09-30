// lib/data/repositories/offers_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/offer.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Offers, combos and happy hour (more-customization Stage 10).
///
/// Every write is an authoring change: it goes live on the next Publish, and
/// from then on each offer starts and stops by itself on the menu.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class OffersRepository {
  Future<List<Offer>> list();
  Future<Offer> create(Offer offer);
  Future<Offer> update(Offer offer);
  Future<Offer> setActive(String id, bool active);
  Future<void> delete(String id);
  Future<OfferPreview> preview(Offer offer);
  Future<List<ProductOffer>> forProduct(String productId);
}

class RemoteOffersRepository implements OffersRepository {
  const RemoteOffersRepository(this._dio);

  final Dio _dio;

  Offer _offer(Map<String, dynamic>? data) {
    final offer = data?['offer'];
    if (offer is! Map<String, dynamic>) throw _malformed;
    return Offer.fromMap(offer);
  }

  @override
  Future<List<Offer>> list() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/offers');
        final list = res.data?['offers'];
        return list is List
            ? list.whereType<Map<String, dynamic>>().map(Offer.fromMap).toList()
            : const <Offer>[];
      });

  @override
  Future<Offer> create(Offer offer) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('/catalog/offers', data: offer.toMap());
        return _offer(res.data);
      });

  @override
  Future<Offer> update(Offer offer) => mapCatalogErrors(() async {
        final res = await _dio.put<Map<String, dynamic>>('/catalog/offers/${offer.id}', data: offer.toMap());
        return _offer(res.data);
      });

  @override
  Future<Offer> setActive(String id, bool active) => mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/offers/$id/active',
          data: {'active': active},
        );
        return _offer(res.data);
      });

  @override
  Future<void> delete(String id) => mapCatalogErrors(() async {
        await _dio.delete<Map<String, dynamic>>('/catalog/offers/$id');
      });

  @override
  Future<OfferPreview> preview(Offer offer) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('/catalog/offers/preview', data: offer.toMap());
        final preview = res.data?['preview'];
        return OfferPreview.fromMap(preview is Map<String, dynamic> ? preview : null);
      });

  @override
  Future<List<ProductOffer>> forProduct(String productId) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/offers/for-product/$productId');
        final list = res.data?['offers'];
        return list is List
            ? list.whereType<Map<String, dynamic>>().map(ProductOffer.fromMap).toList()
            : const <ProductOffer>[];
      });

  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );
}

final offersRepositoryProvider = Provider<OffersRepository>(
  (ref) => RemoteOffersRepository(ref.watch(dioProvider)),
);

final offersListProvider = FutureProvider.autoDispose<List<Offer>>(
  (ref) => ref.watch(offersRepositoryProvider).list(),
);

/// The product editor's "On offer" line. Errors read as "no offers" — the
/// line is a courtesy, never a reason for the editor to show an error.
final productOffersProvider =
    FutureProvider.autoDispose.family<List<ProductOffer>, String>((ref, productId) async {
  try {
    return await ref.watch(offersRepositoryProvider).forProduct(productId);
  } on CatalogFailure {
    return const [];
  }
});
