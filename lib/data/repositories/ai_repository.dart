// lib/data/repositories/ai_repository.dart
//
// Menu import, AI dish descriptions and photo enhancement (more-customization
// Stage 13). The same API is mounted for the owner (`/catalog/…`) and for a
// rep's delegated catalog (`/rep/catalogs/:id/…`); [repCatalogId] picks which.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/menu_import.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

class AiRepository {
  const AiRepository(this._dio, {this.repCatalogId});

  final Dio _dio;
  final String? repCatalogId;

  String get _base => repCatalogId == null ? '/catalog' : '/rep/catalogs/$repCatalogId';

  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );

  MenuImport _import(Map<String, dynamic>? data) {
    final m = data?['import'];
    if (m is! Map<String, dynamic>) throw _malformed;
    return MenuImport.fromMap(m);
  }

  Future<AiStatus> status() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('$_base/ai/status');
        final d = res.data ?? const {};
        return AiStatus(
          enabled: d['enabled'] == true,
          budgetLeft: d['budgetLeft'] == true,
          tone: d['tone'] is String ? d['tone'] as String : 'casual',
        );
      });

  Future<void> setTone(String tone) => mapCatalogErrors(() async {
        await _dio.put<Map<String, dynamic>>('$_base/ai/tone', data: {'tone': tone});
      });

  /// Up to 3 options per dish (≤ 40 dishes). Nothing is saved.
  Future<List<DescriptionSuggestion>> describe(List<String> productIds, {int perDish = 3}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/ai/descriptions',
          data: {'productIds': productIds, 'perDish': perDish},
        );
        final list = res.data?['suggestions'];
        return [
          for (final s in (list is List ? list : const []))
            if (s is Map && s['productId'] is String)
              DescriptionSuggestion(
                productId: s['productId'] as String,
                options: [for (final o in (s['options'] is List ? s['options'] as List : const [])) if (o is String) o],
              ),
        ];
      });

  /// An enhanced copy of the product's photo: `(stagedKey, url)`. Not committed.
  Future<(String, String)> enhance(String productId) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/images/enhance',
          data: {'productId': productId},
        );
        final key = res.data?['imageKey'];
        final url = res.data?['url'];
        if (key is! String || url is! String) throw _malformed;
        return (key, url);
      });

  Future<MenuImport> createImport(List<({String contentType, int size})> files) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/imports',
          data: {
            'files': [for (final f in files) {'contentType': f.contentType, 'size': f.size}],
          },
        );
        return _import(res.data);
      });

  /// One page's bytes, through our API (the web build cannot PUT to S3).
  Future<void> uploadPage(String importId, int page, Uint8List bytes, String contentType) =>
      mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '$_base/imports/$importId/pages/$page',
          data: Stream.value(bytes),
          options: Options(headers: {
            Headers.contentTypeHeader: contentType,
            Headers.contentLengthHeader: bytes.length,
          }),
        );
      });

  Future<MenuImport> start(String importId) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('$_base/imports/$importId/start');
        return _import(res.data);
      });

  Future<MenuImport> get(String importId) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('$_base/imports/$importId');
        return _import(res.data);
      });

  Future<ApplyResult> apply(String importId, List<Map<String, dynamic>> categories) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '$_base/imports/$importId/apply',
          data: {'categories': categories},
        );
        final r = res.data?['result'];
        if (r is! Map) throw _malformed;
        int n(String k) => r[k] is int ? r[k] as int : 0;
        return ApplyResult(created: n('created'), updated: n('updated'), skipped: n('skipped'));
      });

  /// `(removed, kept)` — kept = dishes someone edited since the import.
  Future<(int, int)> undo(String importId) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>('$_base/imports/$importId/undo');
        final d = res.data ?? const {};
        return (d['removed'] is int ? d['removed'] as int : 0, d['kept'] is int ? d['kept'] as int : 0);
      });
}

/// Family key: the rep's catalog id, or null for the owner's own catalog.
final aiRepositoryProvider = Provider.family<AiRepository, String?>(
  (ref, repCatalogId) => AiRepository(ref.watch(dioProvider), repCatalogId: repCatalogId),
);

/// Whether to show any AI button. Any error reads as OFF — a missing key, an
/// older API or a blip must never show a button that then fails.
final aiStatusProvider = FutureProvider.autoDispose.family<AiStatus, String?>((ref, repCatalogId) async {
  try {
    return await ref.watch(aiRepositoryProvider(repCatalogId)).status();
  } catch (_) {
    return AiStatus.off;
  }
});
