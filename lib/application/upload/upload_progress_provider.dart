// lib/application/upload/upload_progress_provider.dart
//
// The seam the Uploading screen (Screen 9) binds to. The screen observes
// [uploadProgressProvider] and renders each [UploadProgress] snapshot — it never
// performs the upload.
//
// The real pipeline is wired: while an upload flow is ACTIVE (uploadFlowProvider
// holds a live [UploadFlowProgress]), this seam delegates to it; when idle it
// falls back to the no-op source that emits one safe initial snapshot — so the
// screen renders the determinate-but-empty pre-total state WITHOUT faking
// progress. Widget tests keep overriding [uploadProgressSourceProvider] with a
// controllable stream. The screen code does not change.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/upload_progress.dart';
import '../../domain/upload/upload_flow_steps.dart';
import 'upload_flow.dart';

/// The progress feed contract. Implementations push [UploadProgress] snapshots as
/// bytes/files transfer and the status changes. Pure interface — no UI, no IO here.
abstract class UploadProgressSource {
  Stream<UploadProgress> watch();
}

/// Idle-state source (no upload flow running): one safe initial snapshot
/// (idle, zero/unknown totals). Also the override point for widget tests.
/// Emits NO fake progress.
class NoUploadProgressSource implements UploadProgressSource {
  const NoUploadProgressSource();

  @override
  Stream<UploadProgress> watch() => Stream<UploadProgress>.value(
        UploadProgress.initial,
      );
}

/// The active progress source: the LIVE upload flow's feed when one exists,
/// else the idle no-op. Tests override this directly (unchanged); the screen
/// always reads through [uploadProgressProvider].
final uploadProgressSourceProvider = Provider<UploadProgressSource>(
  (ref) => ref.watch(uploadFlowProvider) ?? const NoUploadProgressSource(),
);

/// The live upload progress the screen observes. `autoDispose` so the subscription
/// is dropped when the screen leaves and re-established (resuming from the source's
/// current state) when it returns — never reset to a fake 0 by the screen itself.
final uploadProgressProvider = StreamProvider.autoDispose<UploadProgress>(
  (ref) => ref.watch(uploadProgressSourceProvider).watch(),
);

/// The live step-tracker feed for Screen 9: the ACTIVE flow's timeline stream
/// when one exists, else a single all-pending snapshot. The screen stays a
/// pure consumer — live transfer counters come from [uploadProgressProvider]
/// (single source of truth for bytes/files), not from this stream. Widget
/// tests override this provider directly with a controllable stream.
final uploadStepTimelineProvider =
    StreamProvider.autoDispose<UploadFlowTimeline>((ref) {
  final flow = ref.watch(uploadFlowProvider);
  if (flow == null) {
    return Stream<UploadFlowTimeline>.value(UploadFlowTimeline.initial());
  }
  return flow.watchTimeline();
});
