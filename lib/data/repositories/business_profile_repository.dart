// lib/data/repositories/business_profile_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/business_profile.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Data access for the business profile (features 58-60).
///
/// The profile is a view of the catalog document, so a write here bumps the
/// catalog's draft revision exactly like a product edit does — branding reaches
/// customers at publish, never before.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class BusinessProfileRepository {
  /// The caller's profile, or **null when they have no catalog yet**.
  Future<BusinessProfile?> fetch();

  /// Updates the profile.
  ///
  /// [contact] REPLACES the whole contact block — pass the full block from the
  /// form, not a delta. That is deliberate on the server side: a deep merge
  /// would leave no way to clear a single field, and "clear my website" is a
  /// real thing people do.
  Future<BusinessProfile> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  });
}

/// Concrete [BusinessProfileRepository] over the app Dio.
class RemoteBusinessProfileRepository implements BusinessProfileRepository {
  const RemoteBusinessProfileRepository(this._dio);

  final Dio _dio;

  @override
  Future<BusinessProfile?> fetch() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/catalog/profile');
      return _profileFrom(res.data);
    } on DioException catch (error) {
      final failure = CatalogFailure.fromDio(error);
      // No catalog yet is the first-run state, not an error to show.
      if (failure.isNoCatalog) return null;
      throw failure;
    }
  }

  @override
  Future<BusinessProfile> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/profile',
          data: {
            // The schema is `.strict()` and refuses an empty patch, so omitted
            // fields must be absent KEYS rather than nulls.
            if (name != null) 'name': name,
            if (businessName != null) 'businessName': businessName,
            if (contact != null) 'contact': contact.toMap(),
          },
        );
        return _profileFrom(res.data);
      });

  BusinessProfile _profileFrom(Map<String, dynamic>? body) {
    final profile = body?['profile'];
    if (profile is! Map<String, dynamic>) {
      throw const CatalogFailure(
        code: 'MALFORMED_RESPONSE',
        message: 'Something went wrong. Please try again.',
      );
    }
    return BusinessProfile.fromMap(profile);
  }
}

/// App-wide business profile repository.
final businessProfileRepositoryProvider = Provider<BusinessProfileRepository>(
  (ref) => RemoteBusinessProfileRepository(ref.watch(dioProvider)),
);
