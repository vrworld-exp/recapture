// lib/application/catalog/outlet_scope.dart
//
// Stage 16 — switching which outlet the app edits. Every catalog-scoped
// provider holds data of ONE outlet, so a switch drops them all; the next
// screen that watches one reloads it for the new outlet.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/outlet_interceptor.dart';
import '../../data/repositories/offers_repository.dart';
import '../../data/repositories/today_repository.dart';
import '../../data/repositories/weekly_report_repository.dart';
import 'bulk_selection_notifier.dart';
import 'business_profile_notifier.dart';
import 'catalog_analytics_notifier.dart';
import 'catalog_categories_notifier.dart';
import 'catalog_notifier.dart';
import 'catalog_preview_notifier.dart';
import 'catalog_products_notifier.dart';
import 'catalog_qr_notifier.dart';
import 'owner_standee_notifier.dart';
import 'publish_notifier.dart';
import 'subscription_notifier.dart';

export '../../data/remote/outlet_interceptor.dart' show selectedOutletIdProvider;

/// Switches the app to [outletId] (null = the main outlet).
void switchOutlet(WidgetRef ref, String? outletId) {
  if (ref.read(selectedOutletIdProvider) == outletId) return;
  ref.read(selectedOutletIdProvider.notifier).state = outletId;
  ref.read(bulkSelectionProvider.notifier).exit();
  ref
    ..invalidate(catalogProvider)
    ..invalidate(catalogProductsProvider)
    ..invalidate(catalogCategoriesProvider)
    ..invalidate(businessProfileProvider)
    ..invalidate(catalogPreviewProvider)
    ..invalidate(catalogQrProvider)
    ..invalidate(catalogAnalyticsProvider)
    ..invalidate(publishProvider)
    ..invalidate(subscriptionProvider)
    ..invalidate(ownerStandeeProvider)
    ..invalidate(standeeQuotaProvider)
    ..invalidate(offersListProvider)
    ..invalidate(staffListProvider)
    ..invalidate(todayProvider)
    ..invalidate(weeklyReportHistoryProvider);
}
