// lib/application/admin/sales_reps_notifier.dart
//
// The roster behind the "hand this standee to…" picker.
//
// A FutureProvider rather than a Notifier because nothing here has state to
// mutate: the list is fetched once when the sheet opens and thrown away when it
// closes. The ACTION — assigning — lives on AdminBatchCodesNotifier, where the
// row it changes lives, so this provider stays a pure read.
//
// autoDispose is load-bearing rather than idiomatic tidiness: staff roles are
// granted by a script outside the app, so a roster cached for the session would
// keep showing a stale list to the one person able to notice it is stale.
// Re-fetching per sheet costs one request against a handful of rows.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_standee_repository.dart';
import '../../domain/entities/qr_standee.dart';

/// Everyone an admin may hand a standee to, newest fetch each time the picker
/// opens.
final salesRepsProvider = FutureProvider.autoDispose<List<SalesRepSummary>>(
  (ref) => ref.watch(adminStandeeRepositoryProvider).salesReps(),
);
