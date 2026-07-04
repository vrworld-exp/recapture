// lib/application/upload/upload_progress_provider.dart
//
// The seam the Uploading screen (Screen 9) binds to. The screen observes
// [uploadProgressProvider] and renders each [UploadProgress] snapshot — it never
// performs the upload.
//
// The real upload pipeline is a SEPARATE phase task. Until it lands,
// [uploadProgressSourceProvider] resolves to a no-op source that emits a single
// safe initial snapshot — so the screen renders the determinate-but-empty
// pre-total state WITHOUT faking progress (no timers, no animation). The pipeline
// task overrides [uploadProgressSourceProvider] with a real source; widget tests
// override it with a controllable stream. The screen code does not change.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/upload_progress.dart';

/// The progress feed contract. Implementations push [UploadProgress] snapshots as
/// bytes/files transfer and the status changes. Pure interface — no UI, no IO here.
abstract class UploadProgressSource {
  Stream<UploadProgress> watch();
}

/// Default source: the upload pipeline does not exist yet, so emit one safe
/// initial snapshot (idle, zero/unknown totals). Replaced by the real pipeline
/// (and by tests) via [uploadProgressSourceProvider]. Emits NO fake progress.
class NoUploadProgressSource implements UploadProgressSource {
  const NoUploadProgressSource();

  @override
  Stream<UploadProgress> watch() => Stream<UploadProgress>.value(
        UploadProgress.initial,
      );
}

/// The active progress source. Override this to wire the real upload pipeline (or
/// a fake in tests); the screen always reads through [uploadProgressProvider].
final uploadProgressSourceProvider =
    Provider<UploadProgressSource>((ref) => const NoUploadProgressSource());

/// The live upload progress the screen observes. `autoDispose` so the subscription
/// is dropped when the screen leaves and re-established (resuming from the source's
/// current state) when it returns — never reset to a fake 0 by the screen itself.
final uploadProgressProvider = StreamProvider.autoDispose<UploadProgress>(
  (ref) => ref.watch(uploadProgressSourceProvider).watch(),
);
