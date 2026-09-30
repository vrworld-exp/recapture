// lib/data/repositories/weekly_report_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/weekly_report.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Reads for the weekly value report (more-customization Stage 9): the owner's
/// own under `/catalog/reports`, a delegated restaurant's under
/// `/rep/catalogs/:id/reports` when [repCatalogId] is given.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class WeeklyReportRepository {
  Future<WeeklyReportHistory> fetchHistory({String? repCatalogId});

  /// [weekStart] is `YYYY-MM-DD` or `latest`.
  Future<WeeklyReport> fetchReport(String weekStart, {String? repCatalogId});

  /// The owner's switch. Returns the saved value.
  Future<bool> setWeeklyEnabled(bool enabled);
}

class RemoteWeeklyReportRepository implements WeeklyReportRepository {
  const RemoteWeeklyReportRepository(this._dio);

  final Dio _dio;

  String _base(String? repCatalogId) =>
      repCatalogId == null ? '/catalog/reports' : '/rep/catalogs/$repCatalogId/reports';

  @override
  Future<WeeklyReportHistory> fetchHistory({String? repCatalogId}) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(_base(repCatalogId));
        return WeeklyReportHistory.fromMap(res.data);
      });

  @override
  Future<WeeklyReport> fetchReport(String weekStart, {String? repCatalogId}) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('${_base(repCatalogId)}/$weekStart');
        final report = res.data?['report'];
        if (report is! Map<String, dynamic>) throw _malformed;
        return WeeklyReport.fromMap(report);
      });

  @override
  Future<bool> setWeeklyEnabled(bool enabled) => mapCatalogErrors(() async {
        final res = await _dio.put<Map<String, dynamic>>(
          '/catalog/reports/prefs',
          data: {'weekly': enabled},
        );
        final prefs = res.data?['prefs'];
        return prefs is Map<String, dynamic> ? prefs['weekly'] != false : enabled;
      });

  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );
}

final weeklyReportRepositoryProvider = Provider<WeeklyReportRepository>(
  (ref) => RemoteWeeklyReportRepository(ref.watch(dioProvider)),
);

/// The history list. Family key: the rep's catalog id, or null for the owner.
final weeklyReportHistoryProvider =
    FutureProvider.autoDispose.family<WeeklyReportHistory, String?>(
  (ref, repCatalogId) =>
      ref.watch(weeklyReportRepositoryProvider).fetchHistory(repCatalogId: repCatalogId),
);

/// One report. Family key: (weekStart or `latest`, rep catalog id or null).
final weeklyReportProvider =
    FutureProvider.autoDispose.family<WeeklyReport, (String, String?)>(
  (ref, key) => ref
      .watch(weeklyReportRepositoryProvider)
      .fetchReport(key.$1, repCatalogId: key.$2),
);
