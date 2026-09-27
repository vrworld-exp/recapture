// lib/application/catalog/owner_standee_notifier.dart
//
// The owner's "Download standee": N copies of the menu's QR, one per A4 page,
// spent from the plan's complimentary allowance.
//
// ONE NOTIFIER, TWO BUTTONS. The catalog header and the QR screen both start
// the same download, so they share this state: a download started on one is
// busy on the other, and the count they show is the same number.
//
// THE SERVER SPENDS THE COUNT, not this file. The dialog's ceiling comes from
// [standeeQuotaProvider] and is advisory — two phones racing for the last
// standee are settled by the server's guarded write, and the loser gets
// STANDEE_LIMIT_REACHED. After every attempt, successful or not, the quota is
// re-read, so the next dialog opens on the truth.
//
// A SAVE THAT FAILS DOES NOT COST TWICE. Once the server has answered, the
// standees are spent; a dismissed share sheet or a blocked browser download
// must not send the owner back through the dialog to pay again. The file is
// kept as [OwnerStandeeState.unsaved] and [saveAgain] re-delivers those bytes.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';
import 'catalog_qr_service.dart';

/// What the plan's allowance has left. autoDispose: read fresh for each dialog.
final standeeQuotaProvider = AutoDisposeFutureProvider<StandeeQuota>(
  (ref) => ref.watch(catalogRepositoryProvider).fetchStandeeQuota(),
);

@immutable
class OwnerStandeeState {
  const OwnerStandeeState({
    this.busy = false,
    this.failure,
    this.notice,
    this.unsaved,
  });

  final bool busy;
  final CatalogFailure? failure;

  /// A download the server already counted but the device did not save.
  final StandeeDownload? unsaved;

  /// "3 standees saved. 7 left on your plan."
  final String? notice;
}

class OwnerStandeeNotifier extends AutoDisposeNotifier<OwnerStandeeState> {
  bool _disposed = false;

  @override
  OwnerStandeeState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const OwnerStandeeState();
  }

  /// Downloads [copies] standees and hands the PDF to the platform's saver.
  Future<void> download(int copies) async {
    if (state.busy) return;
    state = const OwnerStandeeState(busy: true);

    final StandeeDownload result;
    try {
      result =
          await ref.read(catalogRepositoryProvider).downloadStandees(copies);
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      ref.invalidate(standeeQuotaProvider);
      state = OwnerStandeeState(failure: failure);
      return;
    }
    if (_disposed) return;
    // Spent server-side from here on, whatever the save does.
    ref.invalidate(standeeQuotaProvider);
    await _deliver(result);
  }

  /// Re-saves the last counted download. Spends nothing.
  Future<void> saveAgain() async {
    final unsaved = state.unsaved;
    if (state.busy || unsaved == null) return;
    state = OwnerStandeeState(busy: true, unsaved: unsaved);
    await _deliver(unsaved);
  }

  Future<void> _deliver(StandeeDownload result) async {
    try {
      await ref.read(qrDelivererProvider).deliver(QrDownloadFile(
            bytes: result.file.bytes,
            fileName: result.file.fileName,
            mimeType: result.file.contentType,
          ));
    } catch (_) {
      if (_disposed) return;
      state = OwnerStandeeState(
        unsaved: result,
        failure: const CatalogFailure(
          code: 'QR_SAVE_FAILED',
          message: "We couldn't save the standees. Please try again.",
        ),
      );
      return;
    }
    if (_disposed) return;
    state = OwnerStandeeState(
      notice: savedNotice(result.copies, result.remaining),
    );
  }

  void dismiss() => state = const OwnerStandeeState();
}

/// The confirmation sentence. Public for the widget tests.
String savedNotice(int copies, int? remaining) {
  final saved = copies == 1 ? '1 standee saved.' : '$copies standees saved.';
  if (remaining == null) return saved;
  return remaining == 0
      ? '$saved That was the last one on your plan.'
      : '$saved $remaining left on your plan.';
}

final ownerStandeeProvider =
    AutoDisposeNotifierProvider<OwnerStandeeNotifier, OwnerStandeeState>(
  OwnerStandeeNotifier.new,
);
