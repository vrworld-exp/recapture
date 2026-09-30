// lib/data/repositories/menu_extras_repository.dart
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/menu_entitlements.dart';
import '../../domain/catalog/menu_extras.dart';
import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog_product.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// A QR preview: the PNG, and whether the chosen style failed to scan and the
/// plain square came back instead (`X-Qr-Style-Fallback`).
class QrPreview {
  const QrPreview({required this.bytes, required this.fellBack});

  final Uint8List bytes;
  final bool fellBack;
}

/// Writes for more-customization Stage 7: the 3D viewer's branding, the
/// spotlight carousel, the customer buttons, a dish's pairings, and the QR
/// style (with its live preview).
///
/// Its own interface for the same reason as [MenuTranslationsRepository]: the
/// profile and product repositories are faked by many screen tests, and these
/// writes are only made from the Stage 7 surfaces.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class MenuExtrasRepository {
  /// Each REPLACES its block; the plain / off value removes it.
  Future<BusinessProfile> updateArBranding(ArBranding branding);
  Future<BusinessProfile> updateSpotlight(MenuSpotlight spotlight);
  Future<BusinessProfile> updateEngagement(MenuEngagement engagement);
  Future<BusinessProfile> updateQrStyle(QrStyle style);

  /// A dish's "goes well with" list (≤ [kMaxPairings] other products).
  Future<CatalogProduct> updatePairings(String productId, List<String> productIds);

  /// The owner's QR drawn in [style] without saving it.
  Future<QrPreview> previewQr(QrStyle style, {int size = 512});

  /// What diners said through the feedback form, for an analytics range.
  Future<FeedbackReport> fetchFeedback({String? from, String? to});

  /// Stage 8: what the plan covers, what is held back, and the rollout flag.
  Future<MenuEntitlements> fetchEntitlements();

  /// Stage 8.2: sets (or with null, clears) the menu's pretty address.
  /// Returns the saved slug and its full URL (null when no host is configured).
  Future<(String?, String?)> setSlug(String? slug);
}

class RemoteMenuExtrasRepository implements MenuExtrasRepository {
  const RemoteMenuExtrasRepository(this._dio);

  final Dio _dio;

  Future<BusinessProfile> _patch(Map<String, dynamic> body) => mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>('/catalog/profile', data: body);
        final profile = res.data?['profile'];
        if (profile is! Map<String, dynamic>) throw _malformed;
        return BusinessProfile.fromMap(profile);
      });

  @override
  Future<BusinessProfile> updateArBranding(ArBranding branding) =>
      _patch({'arBranding': branding.isPlain ? null : branding.toMap()});

  @override
  Future<BusinessProfile> updateSpotlight(MenuSpotlight spotlight) => _patch({
        'spotlight': !spotlight.enabled && spotlight.productIds.isEmpty ? null : spotlight.toMap(),
      });

  @override
  Future<BusinessProfile> updateEngagement(MenuEngagement engagement) {
    final map = engagement.toMap();
    final off = !engagement.whatsappOrder &&
        !engagement.callWaiter &&
        !engagement.feedbackForm &&
        !map.containsKey('reviewUrl') &&
        !map.containsKey('wifi');
    return _patch({'engagement': off ? null : map});
  }

  @override
  Future<BusinessProfile> updateQrStyle(QrStyle style) =>
      _patch({'qrStyle': style == QrStyle.plain ? null : style.toMap()});

  @override
  Future<CatalogProduct> updatePairings(String productId, List<String> productIds) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/products/$productId',
          data: {'pairsWith': productIds},
        );
        final product = res.data?['product'];
        if (product is! Map<String, dynamic>) throw _malformed;
        return CatalogProduct.fromMap(product);
      });

  @override
  Future<QrPreview> previewQr(QrStyle style, {int size = 512}) => mapCatalogErrors(() async {
        final res = await _dio.post<List<int>>(
          '/catalog/qr/preview',
          data: {'style': style.toMap(), 'size': size},
          options: Options(responseType: ResponseType.bytes),
        );
        final body = res.data;
        if (body == null || body.isEmpty) throw _malformed;
        return QrPreview(
          bytes: Uint8List.fromList(body),
          fellBack: res.headers.value('x-qr-style-fallback') == '1',
        );
      });

  @override
  Future<FeedbackReport> fetchFeedback({String? from, String? to}) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/analytics/feedback',
          queryParameters: {if (from != null) 'from': from, if (to != null) 'to': to},
        );
        return FeedbackReport.fromMap(res.data);
      });

  @override
  Future<MenuEntitlements> fetchEntitlements() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/entitlements');
        return MenuEntitlements.fromMap(res.data);
      });

  @override
  Future<(String?, String?)> setSlug(String? slug) => mapCatalogErrors(() async {
        final res = await _dio.put<Map<String, dynamic>>('/catalog/slug', data: {'slug': slug});
        final saved = res.data?['slug'];
        final url = res.data?['url'];
        return (saved is String ? saved : null, url is String ? url : null);
      });

  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );
}

final menuExtrasRepositoryProvider = Provider<MenuExtrasRepository>(
  (ref) => RemoteMenuExtrasRepository(ref.watch(dioProvider)),
);

/// Stage 8: the catalog's customization entitlements.
///
/// On an error it reads as "fully covered, visible": an API blip (or an older
/// API without the endpoint) must never paint locks on a paid plan or hide the
/// owner's screens. The rollout flag therefore hides the entry points only when
/// the server EXPLICITLY answers `appearanceEnabled: false` — which it does
/// whenever ops have not set the flag, so "absent = hidden" still holds.
final catalogEntitlementsProvider = FutureProvider.autoDispose<MenuEntitlements>((ref) async {
  try {
    return await ref.watch(menuExtrasRepositoryProvider).fetchEntitlements();
  } on CatalogFailure {
    return const MenuEntitlements(appearanceEnabled: true);
  }
});

/// Stage 8.3: whether to show the customization entry points. True until the
/// server has said otherwise (see above).
final customizationVisibleProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(catalogEntitlementsProvider).valueOrNull?.appearanceEnabled ?? true,
);

/// The feedback report for one analytics range (`(from, to)`).
final catalogFeedbackProvider =
    FutureProvider.autoDispose.family<FeedbackReport, (String?, String?)>(
  (ref, range) =>
      ref.watch(menuExtrasRepositoryProvider).fetchFeedback(from: range.$1, to: range.$2),
);
