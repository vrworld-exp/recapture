// lib/data/repositories/admin_catalogs_repository.dart
//
// The ADMIN's "All catalogs" list — `GET /admin/catalogs`. Read-only: opening
// and editing a catalog goes through [RepRepository] on `/rep/catalogs/:id`,
// whose server gate admits an ADMIN for any live catalog.
//
// Errors surface as [CatalogFailure] (via [mapCatalogErrors]), like every
// catalog-shaped repository.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/admin_catalog_card.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// The server's search bound; a longer query would be a 400.
const int kAdminCatalogQueryMaxLength = 60;

abstract interface class AdminCatalogsRepository {
  Future<AdminCatalogPage> list({String? query, String? cursor});
}

class RemoteAdminCatalogsRepository implements AdminCatalogsRepository {
  const RemoteAdminCatalogsRepository(this._dio);

  final Dio _dio;

  @override
  Future<AdminCatalogPage> list({String? query, String? cursor}) =>
      mapCatalogErrors(() async {
        final q = query?.trim() ?? '';
        final res = await _dio.get<Map<String, dynamic>>(
          '/admin/catalogs',
          queryParameters: {
            if (cursor != null) 'cursor': cursor,
            if (q.isNotEmpty)
              'q': q.length > kAdminCatalogQueryMaxLength
                  ? q.substring(0, kAdminCatalogQueryMaxLength)
                  : q,
          },
        );
        final raw = res.data?['items'];
        return AdminCatalogPage(
          items: raw is List
              ? [
                  for (final item in raw)
                    if (item is Map)
                      if (AdminCatalogCard.fromMap(item.cast<String, dynamic>())
                          case final card?)
                        card,
                ]
              : const [],
          nextCursor: res.data?['nextCursor'] is String
              ? res.data!['nextCursor'] as String
              : null,
        );
      });
}

final adminCatalogsRepositoryProvider = Provider<AdminCatalogsRepository>(
  (ref) => RemoteAdminCatalogsRepository(ref.watch(dioProvider)),
);
