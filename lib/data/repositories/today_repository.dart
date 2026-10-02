// lib/data/repositories/today_repository.dart
//
// Today screen, bulk prices and staff access
// (more-customization Stage 14). The Today API is the same for the owner
// (`/catalog/…`) and a helper (`/staff/catalogs/:id/…`); [staffCatalogId]
// picks which.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/today.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

class TodayRepository {
  const TodayRepository(this._dio, {this.staffCatalogId});

  final Dio _dio;
  final String? staffCatalogId;

  String get _base => staffCatalogId == null ? '/catalog' : '/staff/catalogs/$staffCatalogId';

  Future<TodayData> load() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('$_base/today');
        return TodayData.fromMap(res.data);
      });

  /// One batch. Returns the publish outcome (`QUEUED`, `BLOCKED`, …) when asked to publish.
  Future<String?> save(List<Map<String, dynamic>> changes, {required bool publish}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/today',
          data: {'changes': changes, 'publish': publish},
        );
        return res.data?['publish'] as String?;
      });

  Future<String?> publish() => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('$_base/today/publish');
        return res.data?['publish'] as String?;
      });

  Map<String, dynamic> _bulk(
    List<String> productIds,
    List<String> categoryIds,
    bool percent,
    double amount,
    PriceRounding rounding,
  ) =>
      {
        if (productIds.isNotEmpty) 'productIds': productIds,
        if (categoryIds.isNotEmpty) 'categoryIds': categoryIds,
        'mode': percent ? 'PERCENT' : 'FLAT',
        'amount': amount,
        'rounding': rounding.apiValue,
      };

  Future<List<BulkPreviewRow>> previewBulk({
    required List<String> productIds,
    required List<String> categoryIds,
    required bool percent,
    required double amount,
    required PriceRounding rounding,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/prices/bulk/preview',
          data: _bulk(productIds, categoryIds, percent, amount, rounding),
        );
        return [
          for (final r in (res.data?['rows'] is List ? res.data!['rows'] as List : const []))
            if (r is Map && r['from'] is num)
              BulkPreviewRow(
                name: r['name'] as String? ?? '',
                from: (r['from'] as num).toDouble(),
                to: r['to'] is num ? (r['to'] as num).toDouble() : null,
              ),
        ];
      });

  Future<int> applyBulk({
    required List<String> productIds,
    required List<String> categoryIds,
    required bool percent,
    required double amount,
    required PriceRounding rounding,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/prices/bulk',
          data: _bulk(productIds, categoryIds, percent, amount, rounding),
        );
        return res.data?['changed'] as int? ?? 0;
      });

  /// `(restored, kept)`.
  Future<(int, int)> undoBulk() => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('$_base/prices/undo');
        return (res.data?['restored'] as int? ?? 0, res.data?['kept'] as int? ?? 0);
      });
}

/// Owner-only: staff management.
class StaffRepository {
  const StaffRepository(this._dio);

  final Dio _dio;

  Future<List<StaffMember>> list() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/staff');
        return [
          for (final m in (res.data?['staff'] is List ? res.data!['staff'] as List : const []))
            if (m is Map<String, dynamic>) StaffMember.fromMap(m),
        ];
      });

  Future<void> invite({required String phone, required bool manager, String? name}) => mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>('/catalog/staff', data: {
          'phone': phone,
          'kind': manager ? 'MANAGER' : 'STAFF',
          if ((name ?? '').trim().isNotEmpty) 'name': name!.trim(),
        });
      });

  Future<void> revoke(String id) => mapCatalogErrors(() async {
        await _dio.delete<Map<String, dynamic>>('/catalog/staff/$id');
      });

  /// The restaurants this signed-in person helps run.
  Future<List<StaffCatalog>> myCatalogs() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/staff/catalogs');
        return [
          for (final c in (res.data?['catalogs'] is List ? res.data!['catalogs'] as List : const []))
            if (c is Map<String, dynamic>) StaffCatalog.fromMap(c),
        ];
      });
}

final todayRepositoryProvider = Provider.family<TodayRepository, String?>(
  (ref, staffCatalogId) => TodayRepository(ref.watch(dioProvider), staffCatalogId: staffCatalogId),
);

final todayProvider = FutureProvider.autoDispose.family<TodayData, String?>(
  (ref, staffCatalogId) => ref.watch(todayRepositoryProvider(staffCatalogId)).load(),
);

final staffRepositoryProvider = Provider<StaffRepository>((ref) => StaffRepository(ref.watch(dioProvider)));

final staffListProvider = FutureProvider.autoDispose<List<StaffMember>>(
  (ref) => ref.watch(staffRepositoryProvider).list(),
);

/// The restaurants I help run. Errors read as "none" — this only decides
/// whether to show an entry point.
final myStaffCatalogsProvider = FutureProvider.autoDispose<List<StaffCatalog>>((ref) async {
  try {
    return await ref.watch(staffRepositoryProvider).myCatalogs();
  } catch (_) {
    return const [];
  }
});
