// lib/application/admin/batch_sheet_plan.dart
//
// The printable batch sheet, BEFORE and AFTER the download.
//
// Before: [batchSheetPlanProvider] reads what the sheet would contain, so the
// dialog in front of the Download button can say "50 standees × 10 copies =
// 500 cards over 56 pages" while the admin is still typing the number — and
// before a 56-page file is on its way. A restaurant is handed several standees
// of ONE code (ten tables, one menu), so "copies" is a real question and the
// answer changes the size of the file by an order of magnitude.
//
// After: [batchSheetNotice] is the one sentence both surfaces say once the file
// is saved. Two screens deliver this sheet (the inventory row and the batch
// screen), and the sentence used to be written twice; now that it has a
// copies clause it is written once.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart';

/// What [batchId]'s sheet would contain. Refuses what the sheet refuses.
///
/// autoDispose: the plan is stale the moment a code is retired, and nothing
/// needs it once the dialog closes.
final batchSheetPlanProvider =
    FutureProvider.autoDispose.family<BatchSheetPlan, String>(
  (ref, batchId) =>
      ref.read(adminStandeeRepositoryProvider).batchSheetPlan(batchId),
);

/// The confirmation after a sheet is saved, which NAMES THE SKIPPED CODES
/// when there were any and the COPIES when there were more than one.
///
/// "48 standees" against a run of 50 reads as a bug until something says why;
/// "10 standees over 12 pages" reads as a bug until something says "10 copies
/// each". Degrades to a bare confirmation when the counts did not arrive:
/// they are response headers, and a proxy that strips them must not turn a
/// good download into "Saved 0 standees".
String batchSheetNotice(BatchSheetDownload? sheet) {
  if (sheet == null || sheet.standees == 0) return 'Printable sheet saved.';
  final pages = sheet.pages == 1 ? '1 page' : '${sheet.pages} pages';
  final each = sheet.copies > 1 ? ' × ${sheet.copies} copies' : '';
  final head = 'Saved ${sheet.standees} standees$each over $pages.';
  if (sheet.skippedRetired == 0) return head;
  return '$head ${sheet.skippedRetired} retired and were skipped.';
}
