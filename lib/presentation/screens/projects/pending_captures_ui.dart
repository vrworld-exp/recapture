// lib/presentation/screens/projects/pending_captures_ui.dart
//
// The Projects screen's side of offline capture (Steps C1–C2, C4): which card
// shows a pending label, the "{n} captures waiting to upload · {total} MB"
// strip with Upload all, the card actions (Upload now / Pause / Resume / Retry
// / Delete / Upload as new project / Log in), the mobile-data confirm, and the
// start-capture guard (5-capture limit + free space, offline only).
//
// Everything here reads the pending list and the coordinator; nothing here
// decides policy (auto_upload_policy.dart, pending_capture_label.dart and
// offline_capture_limits.dart do). Native only: every entry point is a no-op
// when offlineCaptureCapabilityProvider is false, so the web Projects screen is
// unchanged.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/auth_notifier.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../application/projects/projects_notifier.dart';
import '../../../application/upload/offline_capture_capability.dart';
import '../../../application/upload/pending_captures_notifier.dart';
import '../../../application/upload/pending_upload_coordinator.dart';
import '../../../application/upload/upload_prefs_provider.dart';
import '../../../application/upload/upload_progress_provider.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_status.dart';
import '../../../domain/upload/auto_upload_policy.dart';
import '../../../domain/upload/offline_capture_limits.dart';
import '../../../domain/upload/pending_capture.dart';
import '../../../domain/upload/pending_capture_label.dart';
import '../../../platform/capture_storage.dart';
import '../../../platform/connectivity_watcher.dart';
import '../../widgets/app_button.dart';
import '../../widgets/pending_capture_card_parts.dart';

/// The copy for the delete confirmation of a never-uploaded capture.
const String kPendingDeleteWarning =
    'This capture was never uploaded. Deleting it removes the photos from '
    'this phone permanently.';

/// The pieces a project card needs for its pending capture, or null.
class PendingCardParts {
  const PendingCardParts({required this.pill, required this.actions});
  final Widget pill;
  final Widget actions;
}

/// The network as the policy sees it.
UploadNetwork pendingNetworkOf(WidgetRef ref) {
  if (!ref.watch(isOnlineProvider)) return UploadNetwork.none;
  return switch (ref.watch(currentNetworkTypeProvider)) {
    AppNetworkType.unmetered => UploadNetwork.unmetered,
    AppNetworkType.metered => UploadNetwork.metered,
    AppNetworkType.none => UploadNetwork.none,
  };
}

/// The signed-in user's waiting captures ([] on web).
List<PendingCapture> watchPendingCaptures(WidgetRef ref) =>
    ref.watch(offlineCaptureCapabilityProvider)
        ? ref.watch(pendingCapturesProvider)
        : const [];

/// [watchPendingCaptures] for callbacks (never `watch` outside build).
List<PendingCapture> readPendingCaptures(WidgetRef ref) =>
    ref.read(offlineCaptureCapabilityProvider)
        ? ref.read(pendingCapturesProvider)
        : const [];

/// [projects] plus a row for every waiting capture whose project is not in
/// the list (an offline-created project the list no longer carries, e.g.
/// after a logout cleared the cache). Those rows come first, newest capture
/// first — a waiting capture must never be invisible.
List<Project> mergeProjectsWithPending(
  List<Project> projects,
  List<PendingCapture> pending,
) {
  if (pending.isEmpty) return projects;
  final known = {for (final p in projects) p.id};
  final extra = <Project>[];
  for (final c in pending.reversed) {
    if (known.add(c.projectId)) {
      extra.add(Project(
        id: c.projectId,
        name: c.projectName,
        status: ProjectStatus.draft,
        updatedAt: c.capturedAt.toLocal(),
        isPending: c.hasPendingProject,
      ));
    }
  }
  return [...extra, ...projects];
}

/// The newest waiting capture of [projectId], if any.
PendingCapture? pendingFor(List<PendingCapture> pending, String projectId) {
  PendingCapture? found;
  for (final c in pending) {
    if (c.projectId == projectId) found = c;
  }
  return found;
}

/// Builds the pending pill + actions for [capture]'s card.
PendingCardParts? pendingCardPartsFor(
  BuildContext context,
  WidgetRef ref,
  PendingCapture capture,
) {
  final coordinator = ref.watch(pendingUploadCoordinatorProvider);
  final network = pendingNetworkOf(ref);
  final isActive = coordinator.activeLocalId == capture.localId;
  final kind = pendingLabelFor(
    capture,
    network: network,
    settings: ref.watch(autoUploadSettingsProvider),
    isActive: isActive,
    needsLogin: coordinator.needsLogin,
  );
  if (kind == null) return null;
  int? percent;
  if (isActive) {
    // The ONE progress source (the live flow's feed) — never recomputed here.
    final p = ref.watch(uploadProgressProvider).valueOrNull;
    if (p != null && p.totalBytes > 0) {
      percent = (p.fraction * 100).floor().clamp(0, 100);
    }
  }
  return PendingCardParts(
    pill: PendingCardPill(kind: kind, percent: percent),
    actions: PendingCardActions(
      kind: kind,
      percent: percent,
      reason: pendingFailureReason(capture.lastErrorCode),
      uploadEnabled: network != UploadNetwork.none,
      onAction: (a) => unawaited(onPendingAction(context, ref, capture, a)),
    ),
  );
}

/// Runs a card action for [capture].
Future<void> onPendingAction(
  BuildContext context,
  WidgetRef ref,
  PendingCapture capture,
  PendingCardAction action,
) async {
  final coordinator = ref.read(pendingUploadCoordinatorProvider.notifier);
  switch (action) {
    case PendingCardAction.uploadNow:
    case PendingCardAction.retry:
    case PendingCardAction.resume:
      await _uploadNowWithConfirm(context, ref, capture);
    case PendingCardAction.pause:
      await coordinator.pause(capture.localId);
    case PendingCardAction.delete:
      final ok = await _confirmDelete(context);
      if (!ok) return;
      await deletePendingCapture(ref, capture);
    case PendingCardAction.uploadAsNew:
      await coordinator.uploadAsNewProject(capture.localId);
    case PendingCardAction.logIn:
      // The router guard sends a signed-out user to the auth flow. The capture
      // stays on the phone for this account and uploads after the login.
      await ref.read(authProvider.notifier).logout();
  }
}

/// Deletes a never-uploaded capture (confirmation already given) and, when it
/// was the last one of an offline-only project, that project's local row and
/// queued create too.
Future<void> deletePendingCapture(WidgetRef ref, PendingCapture capture) async {
  await ref
      .read(pendingUploadCoordinatorProvider.notifier)
      .deletePending(capture.localId);
  final stillWaiting = ref
      .read(pendingCapturesProvider)
      .any((c) => c.projectId == capture.projectId);
  if (!stillWaiting && capture.hasPendingProject) {
    await ref
        .read(projectsProvider.notifier)
        .discardPendingProject(capture.projectId);
  }
}

Future<void> _uploadNowWithConfirm(
  BuildContext context,
  WidgetRef ref,
  PendingCapture capture,
) async {
  final coordinator = ref.read(pendingUploadCoordinatorProvider.notifier);
  var result = await coordinator.uploadNow(capture.localId);
  if (result == UploadNowResult.needsMobileDataConfirm) {
    if (!context.mounted) return;
    final yes = await confirmMobileData(context, capture.byteCount);
    if (!yes) return;
    result = await coordinator.uploadNow(
      capture.localId,
      confirmedMobileData: true,
    );
  }
  if (result == UploadNowResult.offline && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Connect to the internet to upload.'),
    ));
  }
}

/// "This upload is about {size} MB. Use mobile data?" — true on Upload.
Future<bool> confirmMobileData(BuildContext context, int bytes) async {
  final mb = (bytes / (1024 * 1024)).ceil();
  final yes = await showDialog<bool>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (ctx) => AlertDialog(
      key: const Key('mobile_data_confirm'),
      backgroundColor: AppColors.surface1,
      title: const Text('Use mobile data?'),
      content: Text('This upload is about $mb MB. Use mobile data?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Not now'),
        ),
        TextButton(
          key: const Key('mobile_data_confirm_yes'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Upload'),
        ),
      ],
    ),
  );
  return yes == true;
}

Future<bool> _confirmDelete(BuildContext context) async {
  final yes = await showDialog<bool>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (ctx) => AlertDialog(
      key: const Key('pending_delete_confirm'),
      backgroundColor: AppColors.surface1,
      title: const Text('Delete this capture?'),
      content: const Text(kPendingDeleteWarning),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('pending_delete_confirm_yes'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete', style: TextStyle(color: AppColors.error)),
        ),
      ],
    ),
  );
  return yes == true;
}

/// The slim strip above the list: "{n} captures waiting to upload · {total}
/// MB" with Upload all. Renders nothing when no capture waits.
class PendingCapturesStrip extends ConsumerWidget {
  const PendingCapturesStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = watchPendingCaptures(ref);
    if (pending.isEmpty) return const SizedBox.shrink();
    final totalMb = (pending.fold<int>(0, (s, c) => s + c.byteCount) /
            (1024 * 1024))
        .ceil();
    final online = ref.watch(isOnlineProvider);
    final n = pending.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
      child: Container(
        key: const Key('pending_strip'),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(Icons.phone_android, size: 16, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '$n capture${n == 1 ? '' : 's'} waiting to upload · $totalMb MB',
                softWrap: true,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton.secondary(
              key: const Key('pending_upload_all'),
              label: 'Upload all',
              isFullWidth: false,
              onPressed: online ? () => _uploadAll(context, ref) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadAll(BuildContext context, WidgetRef ref) async {
    await uploadAllWithConfirm(context, ref);
  }
}

/// "Upload all" (also the logout dialog's "Upload first"): starts everything
/// that may go, and asks ONCE about the Full captures that need mobile data.
Future<void> uploadAllWithConfirm(BuildContext context, WidgetRef ref) async {
  final coordinator = ref.read(pendingUploadCoordinatorProvider.notifier);
  final needConfirm = await coordinator.uploadAll();
  if (needConfirm.isEmpty || !context.mounted) return;
  final notifier = ref.read(pendingCapturesProvider.notifier);
  final bytes = needConfirm
      .map(notifier.byLocalId)
      .whereType<PendingCapture>()
      .fold<int>(0, (s, c) => s + c.byteCount);
  final yes = await confirmMobileData(context, bytes);
  if (!yes) return;
  for (final id in needConfirm) {
    await coordinator.uploadNow(
      id,
      trigger: PendingUploadTrigger.uploadAll,
      confirmedMobileData: true,
    );
  }
}

/// The C2 guard on the start-capture entry point. Returns true when the
/// capture may start; otherwise shows why and returns false. Online, or on a
/// build without offline capture, it never blocks.
Future<bool> guardOfflineCaptureStart(
  BuildContext context,
  WidgetRef ref, {
  required String modeId,
  CaptureStorageClient? storage,
}) async {
  if (!ref.read(offlineCaptureCapabilityProvider)) return true;
  final online = ref.read(isOnlineProvider);
  if (online) return true;
  final pendingNotifier = ref.read(pendingCapturesProvider.notifier);
  await pendingNotifier.whenLoaded();
  int? free;
  try {
    final v = await (storage ?? CaptureStorageClient()).freeSpaceBytes();
    free = v > 0 ? v : null; // 0 = the probe did not answer → unknown
  } catch (_) {
    free = null;
  }
  final block = offlineCaptureBlock(
    online: online,
    pendingCount: ref.read(pendingCapturesProvider).length,
    modeId: modeId,
    freeBytes: free,
  );
  if (block == null) return true;
  if (!context.mounted) return false;
  final message = switch (block) {
    OfflineCaptureBlock.tooManyPending =>
      'You have $kMaxPendingCapturesPerUser captures waiting to upload. '
          'Connect to the internet to upload them before capturing more.',
    OfflineCaptureBlock.lowStorage =>
      'Not enough free space on this phone for this capture. You need about '
          '${(requiredFreeBytesFor(modeId) / (1024 * 1024)).ceil()} MB free. '
          'Free up some space, or connect to the internet so waiting '
          'captures can upload.',
  };
  await showDialog<void>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (ctx) => AlertDialog(
      key: Key('offline_capture_block_${block.name}'),
      backgroundColor: AppColors.surface1,
      title: const Text("Can't start this capture"),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return false;
}
