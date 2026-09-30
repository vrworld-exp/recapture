// lib/data/repositories/customers_repository.dart
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// One diner on the WhatsApp-offers list (more-customization Stage 12.2).
class CustomerContact {
  const CustomerContact({
    required this.id,
    required this.phone,
    required this.consentAt,
    required this.optedOut,
    this.name,
    this.birthdayDay,
    this.birthdayMonth,
  });

  final String id;

  /// "+91…".
  final String phone;
  final String? name;
  final int? birthdayDay;
  final int? birthdayMonth;
  final DateTime? consentAt;
  final bool optedOut;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "12 Mar", or null.
  String? get birthdayLabel =>
      birthdayDay == null || birthdayMonth == null ? null : '$birthdayDay ${_months[birthdayMonth! - 1]}';

  factory CustomerContact.fromMap(Map<String, dynamic> m) {
    final b = m['birthday'];
    return CustomerContact(
      id: m['id'] as String? ?? '',
      phone: m['phone'] as String? ?? '',
      name: m['name'] is String ? m['name'] as String : null,
      birthdayDay: b is Map && b['day'] is int ? b['day'] as int : null,
      birthdayMonth: b is Map && b['month'] is int ? b['month'] as int : null,
      consentAt: DateTime.tryParse(m['consentAt'] as String? ?? ''),
      optedOut: m['optedOut'] == true,
    );
  }
}

class CustomerList {
  const CustomerList({
    required this.customers,
    required this.subscribed,
    required this.optedOut,
    required this.birthdaysThisWeek,
    required this.fresh,
    required this.optInEnabled,
  });

  final List<CustomerContact> customers;
  final int subscribed;
  final int optedOut;
  final List<CustomerContact> birthdaysThisWeek;

  /// False when the menu server could not be reached — this is the stored list.
  final bool fresh;
  final bool optInEnabled;

  factory CustomerList.fromMap(Map<String, dynamic>? map) {
    final m = map ?? const <String, dynamic>{};
    List<CustomerContact> list(Object? v) =>
        v is List ? v.whereType<Map<String, dynamic>>().map(CustomerContact.fromMap).toList() : const [];
    return CustomerList(
      customers: list(m['customers']),
      subscribed: m['subscribed'] is int ? m['subscribed'] as int : 0,
      optedOut: m['optedOut'] is int ? m['optedOut'] as int : 0,
      birthdaysThisWeek: list(m['birthdaysThisWeek']),
      fresh: m['fresh'] != false,
      optInEnabled: m['optInEnabled'] == true,
    );
  }
}

/// Owner-only reads and writes for the customer list. Every method throws
/// [CatalogFailure] on failure — never a [DioException].
class CustomersRepository {
  const CustomersRepository(this._dio);

  final Dio _dio;

  Future<CustomerList> list({String? query}) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/customers',
          queryParameters: {if ((query ?? '').trim().isNotEmpty) 'q': query!.trim()},
        );
        return CustomerList.fromMap(res.data);
      });

  /// The CSV (subscribed contacts only). The server audit-logs every export.
  Future<Uint8List> exportCsv() => mapCatalogErrors(() async {
        final res = await _dio.get<List<int>>(
          '/catalog/customers/export',
          options: Options(responseType: ResponseType.bytes),
        );
        return Uint8List.fromList(res.data ?? const []);
      });

  Future<void> markOptedOut(String id) => mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>('/catalog/customers/$id/opt-out');
      });

  Future<void> delete(String id) => mapCatalogErrors(() async {
        await _dio.delete<Map<String, dynamic>>('/catalog/customers/$id');
      });
}

final customersRepositoryProvider = Provider<CustomersRepository>(
  (ref) => CustomersRepository(ref.watch(dioProvider)),
);

/// Family key: the search text ('' = everyone).
final customerListProvider = FutureProvider.autoDispose.family<CustomerList, String>(
  (ref, query) => ref.watch(customersRepositoryProvider).list(query: query),
);
