// lib/application/standee_sheet_plan.dart
//
// What ONE code's printable sheet would take — read before the download.
//
// Two providers for two doors to the same plan: the admin's, for any code, and
// the rep's, for a code they hold. The dialog in front of the single-standee
// download (`standee_copies_dialog.dart`) takes whichever the screen hands it
// and does not know which side of the house it is on — the plan has the same
// shape either way (the grid, and the copies ceiling), and both refuse a
// retired code the same way the download would.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/admin_standee_repository.dart';
import '../data/repositories/rep_repository.dart';
import '../data/repositories/standee_sheet.dart';

/// The admin's read, for any code. autoDispose: nothing needs it once the
/// dialog closes, and a retirement makes it stale.
final adminStandeeSheetPlanProvider =
    FutureProvider.autoDispose.family<StandeeSheetPlan, String>(
  (ref, code) =>
      ref.read(adminStandeeRepositoryProvider).standeeSheetPlan(code),
);

/// The rep's read, for a code they hold. A code they do not hold fails the
/// same way the download would, so the dialog says so before offering it.
final repStandeeSheetPlanProvider =
    FutureProvider.autoDispose.family<StandeeSheetPlan, String>(
  (ref, code) => ref.read(repRepositoryProvider).standeeSheetPlan(code),
);
