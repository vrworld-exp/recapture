// lib/presentation/screens/projects/photo_upload_progress_screen.dart
//
// The screen an artist lands on the moment they tap "Upload N photos": the
// transfer itself, photo by photo, live.
//
// ── WHY THE UPLOAD RUNS HERE AND NOT ON THE FORM ────────────────────────────
// The form used to `await` the whole upload behind a spinner on its CTA and
// then route onward. A 48-photo set is minutes of that, with nothing to look
// at and no way to tell a slow photo from a stuck one. Starting the run HERE
// makes the wait the screen's whole subject: every picked photo gets a row,
// and each row says queued / uploading / uploaded / failed as it happens.
//
// ── WHY A PUSH, NOT A go() REPLACEMENT ──────────────────────────────────────
// [projectPhotosProvider] is autoDispose and holds the picked set. Replacing
// the form would tear its last listener down mid-flight and take the set with
// it. A push keeps the form mounted underneath, so the provider — and the
// upload — survive. It also needs no `flow_back.dart` mapping: this is a
// pushed route, so hardware back pops it.
//
// ── WHERE IT GOES WHEN IT FINISHES ──────────────────────────────────────────
// The Projects hub. An upload is finished when the photos are on S3 and the
// project exists; asking the artist to hand-pick 3-4 photos for a 3D model in
// the same breath conflates two decisions. The project lands in the list like
// any other captured project — Preview, Models and "Generate 3D model", with
// picking one tap deeper inside Preview whenever they want it.
//
// ── PER-PHOTO STATUS IS DERIVED, NOT INVENTED ───────────────────────────────
// Every status on this screen comes from [ProjectPhotosState.statusForPhoto],
// which reads the engine's own aggregate progress feed. This screen computes
// nothing about the transfer — the same rule the capture Uploading screen
// follows.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/project_photos_notifier.dart';
import '../../../application/projects/projects_notifier.dart';
import '../../../data/datasources/project_photo_picker.dart';
import '../../../utils/byte_format.dart';
import '../../widgets/app_button.dart';

class PhotoUploadProgressScreen extends ConsumerStatefulWidget {
  const PhotoUploadProgressScreen({super.key, required this.projectName});

  /// The name typed on the form. The project does not exist yet — step 1 of
  /// the flow creates it with this name.
  final String projectName;

  @override
  ConsumerState<PhotoUploadProgressScreen> createState() =>
      _PhotoUploadProgressScreenState();
}

class _PhotoUploadProgressScreenState
    extends ConsumerState<PhotoUploadProgressScreen> {
  @override
  void initState() {
    super.initState();
    // Post-frame: `upload()` mutates the provider, which must not happen while
    // the first build is still running.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    // A retry after a failure reuses the project the first attempt created —
    // the notifier hands it back to the flow, so a second run never leaves a
    // second draft project behind.
    await ref
        .read(projectPhotosProvider.notifier)
        .upload(name: widget.projectName);
    if (!mounted) return;
    // The hub's list state does not know about this project: the flow created
    // it straight through the repository, deliberately bypassing
    // ProjectsNotifier (whose offline branch would have handed back a
    // temporary local id the photo session cannot use). Refreshing here is
    // what puts it in the list, so "Done" lands on a hub that already shows it.
    if (ref.read(projectPhotosProvider).isUploadComplete) {
      unawaited(
        ref.read(projectsProvider.notifier).refresh().catchError((_) {}),
      );
    }
  }

  void _done() => context.goNamed(AppRouteNames.projects);

  /// Cancels the transfer and leaves. The picked set is retained, so backing
  /// out of the dialog and letting it finish is always an option.
  Future<void> _confirmCancel() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: const Text('Stop uploading?'),
        content: const Text(
          'The photos already uploaded are kept, and the project stays in your '
          'list. You can upload the rest later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep uploading'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    ref.read(projectPhotosProvider.notifier).cancelUpload();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectPhotosProvider);
    final theme = Theme.of(context);
    final inFlight = state.isBusy;

    return PopScope(
      // Back must not abandon a live transfer silently — it asks first, and
      // `onPopInvokedWithResult` is where the ask happens because `canPop`
      // has already blocked the pop itself.
      canPop: !inFlight,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && inFlight) _confirmCancel();
      },
      child: Scaffold(
        backgroundColor: AppColors.bgPrimary,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          leading: inFlight
              ? IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textPrimary),
                  onPressed: _confirmCancel,
                  tooltip: 'Stop uploading',
                )
              : null,
          title: Text('Uploading photos', style: theme.textTheme.titleLarge),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              _Summary(state: state),
              const Divider(height: 1, color: AppColors.surface2),
              Expanded(
                child: ListView.separated(
                  key: const Key('photo_upload_progress_list'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  itemCount: state.picked.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.md),
                  itemBuilder: (_, i) {
                    final status = state.statusForPhoto(i);
                    return _PhotoRow(
                      photo: state.picked[i],
                      status: status,
                      // Only the photo in flight has a partial byte count worth
                      // showing; every other row is all-or-nothing.
                      bytesUploaded: status == PhotoTransferStatus.uploading
                          ? state.activePhotoBytesUploaded
                          : null,
                    );
                  },
                ),
              ),
              _Footer(
                state: state,
                onDone: _done,
                onRetry: _start,
                onBack: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The headline: one sentence for the phase, the overall bar, and the counts.
class _Summary extends StatelessWidget {
  const _Summary({required this.state});

  final ProjectPhotosState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = state.picked.length;
    final failed = state.phase == PhotoUploadPhase.failed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _headline(state),
            key: const Key('photo_upload_headline'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: LinearProgressIndicator(
              value: state.progress,
              minHeight: 6,
              backgroundColor: AppColors.surface2,
              valueColor: AlwaysStoppedAnimation<Color>(
                failed ? AppColors.error : AppColors.mirageRed,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${state.uploadedFiles} of $total photos'
            '${state.totalBytes > 0 ? ' · ${formatMbProgress(state.uploadedBytes, state.totalBytes)}' : ''}',
            style:
                theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          if (state.message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              state.message!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: failed ? AppColors.error : AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _headline(ProjectPhotosState state) => switch (state.phase) {
        PhotoUploadPhase.creating => 'Preparing your project…',
        PhotoUploadPhase.uploading => 'Uploading your photos…',
        PhotoUploadPhase.committing => 'Finishing up…',
        PhotoUploadPhase.completed => 'All photos uploaded.',
        PhotoUploadPhase.failed => "The upload didn't finish.",
        _ => 'Getting ready…',
      };
}

/// One photo's row: its name, its size, and where it is right now.
class _PhotoRow extends StatelessWidget {
  const _PhotoRow({
    required this.photo,
    required this.status,
    required this.bytesUploaded,
  });

  final PickedProjectPhoto photo;
  final PhotoTransferStatus status;

  /// Bytes confirmed for THIS photo, or null when a partial count is not
  /// meaningful (anything that is not the photo in flight).
  final int? bytesUploaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = status == PhotoTransferStatus.uploading && photo.size > 0
        ? ((bytesUploaded ?? 0) / photo.size).clamp(0.0, 1.0)
        : null;

    return Row(
      children: [
        SizedBox(width: 28, child: _StatusIcon(status: status)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                photo.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: status == PhotoTransferStatus.queued
                      ? AppColors.textMuted
                      : AppColors.textPrimary,
                ),
              ),
              if (fraction != null) ...[
                const SizedBox(height: AppSpacing.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 3,
                    backgroundColor: AppColors.surface2,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.mirageRed,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          _trailing(status, photo.size),
          style: theme.textTheme.bodySmall?.copyWith(
            color: switch (status) {
              PhotoTransferStatus.failed => AppColors.error,
              PhotoTransferStatus.uploaded => AppColors.textSecondary,
              _ => AppColors.textMuted,
            },
          ),
        ),
      ],
    );
  }

  static String _trailing(PhotoTransferStatus status, int size) =>
      switch (status) {
        PhotoTransferStatus.queued => 'Waiting',
        PhotoTransferStatus.uploading => 'Uploading',
        PhotoTransferStatus.uploaded => '${formatMb(size)} MB',
        PhotoTransferStatus.failed => 'Failed',
      };
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final PhotoTransferStatus status;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      PhotoTransferStatus.queued => const Icon(
          Icons.schedule,
          size: 18,
          color: AppColors.textMuted,
        ),
      PhotoTransferStatus.uploading => const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.mirageRed),
          ),
        ),
      PhotoTransferStatus.uploaded => const Icon(
          Icons.check_circle,
          size: 18,
          color: AppColors.success,
        ),
      PhotoTransferStatus.failed => const Icon(
          Icons.error_outline,
          size: 18,
          color: AppColors.error,
        ),
    };
  }
}

/// The CTA area: nothing to press while the transfer runs (stopping lives in
/// the app bar), Done on success, Try again on failure.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.state,
    required this.onDone,
    required this.onRetry,
    required this.onBack,
  });

  final ProjectPhotosState state;
  final VoidCallback onDone;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    if (state.isBusy) return const SizedBox(height: AppSpacing.lg);

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: state.isUploadComplete
          ? AppButton(
              key: const Key('photo_upload_done'),
              label: 'Done',
              onPressed: onDone,
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppButton(
                  key: const Key('photo_upload_retry'),
                  label: 'Try again',
                  onPressed: onRetry,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton.secondary(
                  key: const Key('photo_upload_back'),
                  label: 'Back to the photo list',
                  onPressed: onBack,
                ),
              ],
            ),
    );
  }
}
