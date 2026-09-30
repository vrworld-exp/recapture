// lib/data/repositories/outlets_repository.dart
//
// Stage 16 — a restaurant's outlets: the main one and its branches.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/outlet.dart';
import '../remote/api_client.dart';
import '../remote/outlet_interceptor.dart';
import 'catalog_failure.dart';

class OutletsRepository {
  const OutletsRepository(this._dio);

  final Dio _dio;

  Future<List<Outlet>> list() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/outlets');
        final rows = res.data?['outlets'];
        return [
          for (final r in (rows is List ? rows : const []))
            if (r is Map<String, dynamic>) Outlet.fromMap(r),
        ];
      });

  Future<Outlet> addBranch({
    required String outletName,
    String? phone,
    String? address,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/outlets',
          data: {
            'outletName': outletName.trim(),
            if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
            if (address != null && address.trim().isNotEmpty) 'address': address.trim(),
          },
        );
        return Outlet.fromMap(res.data?['outlet'] as Map<String, dynamic>? ?? const {});
      });

  Future<List<PublishAllResult>> publishAll() => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('/catalog/outlets/publish-all');
        final rows = res.data?['results'];
        return [
          for (final r in (rows is List ? rows : const []))
            if (r is Map<String, dynamic>) PublishAllResult.fromMap(r),
        ];
      });

  /// "Reset to main outlet" for one dish on a branch.
  Future<void> resetProduct({required String outletId, required String productId}) =>
      mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/catalog/outlets/$outletId/products/$productId/reset',
        );
      });
}

final outletsRepositoryProvider = Provider<OutletsRepository>(
  (ref) => OutletsRepository(ref.watch(dioProvider)),
);

/// Every outlet of the signed-in owner's restaurant (main first).
final outletsProvider = FutureProvider.autoDispose<List<Outlet>>((ref) {
  ref.watch(selectedOutletIdProvider);
  return ref.watch(outletsRepositoryProvider).list();
});
