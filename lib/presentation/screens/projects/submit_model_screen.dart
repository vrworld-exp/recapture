// lib/presentation/screens/projects/submit_model_screen.dart
//
// The staff "Submit model" screen: hand a finished `.glb` to a project you do
// not own, so its owner gets a model without a generation ever running.
//
// ── THE PROJECT NAME IS THE POINT ───────────────────────────────────────────
// This is the one screen in the app where the user acts on SOMEONE ELSE'S
// project, and the only guard against submitting to the wrong one is knowing
// which one they are on. So the name is the headline, not a subtitle — and it
// is passed in from the row that was tapped rather than fetched, because the
// row already has it and a second request could only ever disagree with it.
//
// ── ONE SUCCESS SENTENCE, AND IT NAMES THE OWNER'S SCREEN ───────────────────
// Nothing here can show the submitter what the owner now sees, so the
// confirmation says where the model went in words. That sentence is the whole
// feedback loop for this feature.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/model_submission_notifier.dart';
import '../../../data/datasources/model_file_picker.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class SubmitModelScreen extends ConsumerWidget {
  const SubmitModelScreen({
    super.key,
    required this.projectId,
    required this.projectName,
  });

  final String projectId;

  /// The project's display name, passed from the Live row. Empty on a cold
  /// deep-link, which the header falls back for rather than showing a blank.
  final String projectName;

  String get _displayName =>
      projectName.trim().isEmpty ? 'this project' : projectName.trim();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(modelSubmissionProvider(projectId));
    final notifier = ref.read(modelSubmissionProvider(projectId).notifier);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
          tooltip: 'Back',
          // Locked mid-upload: leaving would abandon a transfer the user has
          // already spent minutes on, with no way back into it.
          onPressed: state.isBusy ? null : () => navigateBack(context),
        ),
        title: Text(
          'Submit model',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              'Submitting model for',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _displayName,
              key: const ValueKey('submit_model_project_name'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (state.phase == ModelSubmissionPhase.submitted)
              _SuccessCard(
                projectName: _displayName,
                onSubmitAnother: notifier.reset,
                onDone: () => navigateBack(context),
              )
            else ...[
              _FilePickerCard(
                file: state.file,
                oversized: state.oversized,
                enabled: !state.isBusy,
                onPick: notifier.pickFile,
              ),
              if (state.oversized) ...[
                const SizedBox(height: AppSpacing.sm),
                const _Notice(
                  icon: Icons.warning_amber_rounded,
                  color: AppColors.warning,
                  message:
                      'That model is larger than the server accepts. Optimize '
                      'it or export a smaller one, then choose it again.',
                ),
              ],
              if (state.failure != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _Notice(
                  icon: Icons.error_outline,
                  color: AppColors.error,
                  message: modelSubmissionFailureMessage(state.failure!),
                ),
              ],
              if (state.phase == ModelSubmissionPhase.uploading) ...[
                const SizedBox(height: AppSpacing.lg),
                _UploadProgress(progress: state.progress),
              ],
              if (state.phase == ModelSubmissionPhase.finalizing) ...[
                const SizedBox(height: AppSpacing.lg),
                const _Notice(
                  icon: Icons.hourglass_top,
                  color: AppColors.textMuted,
                  message: 'Upload complete — adding it to the project…',
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                child: AppButton(
                  key: const ValueKey('submit_model_button'),
                  label: 'Submit model',
                  icon: Icons.cloud_upload_outlined,
                  isLoading: state.isBusy,
                  onPressed: state.canSubmit ? notifier.submit : null,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Only .glb files. The owner sees the model in their projects as '
                'soon as it is submitted.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The pick affordance, and — once something is chosen — what was chosen.
class _FilePickerCard extends StatelessWidget {
  const _FilePickerCard({
    required this.file,
    required this.oversized,
    required this.enabled,
    required this.onPick,
  });

  final PickedModelFile? file;
  final bool oversized;
  final bool enabled;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final chosen = file;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chosen == null)
            Text(
              'No file chosen yet.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textMuted),
            )
          else
            Row(
              children: [
                Icon(
                  Icons.view_in_ar_outlined,
                  size: 20,
                  color: oversized ? AppColors.warning : AppColors.success,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chosen.name,
                        key: const ValueKey('submit_model_file_name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        formatModelBytes(chosen.size),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: AppButton.secondary(
              key: const ValueKey('submit_model_choose_button'),
              label: chosen == null ? 'Choose .glb file' : 'Choose a different file',
              icon: Icons.folder_open_outlined,
              onPressed: enabled ? onPick : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadProgress extends StatelessWidget {
  const _UploadProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final percent = (progress * 100).clamp(0, 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Uploading — $percent%',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: LinearProgressIndicator(
            // Determinate from the first byte: an indeterminate bar on a
            // multi-minute transfer tells the user nothing.
            value: progress,
            minHeight: 6,
            backgroundColor: AppColors.surface1,
            color: AppColors.mirageRed,
          ),
        ),
      ],
    );
  }
}

class _SuccessCard extends StatelessWidget {
  const _SuccessCard({
    required this.projectName,
    required this.onSubmitAnother,
    required this.onDone,
  });

  final String projectName;
  final VoidCallback onSubmitAnother;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: AppColors.success, size: 22),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Model submitted',
                  key: const ValueKey('submit_model_success'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'It’s now on $projectName, and the owner can see it in their '
            'projects.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton.secondary(
                  label: 'Submit another',
                  icon: Icons.add,
                  onPressed: onSubmitAnother,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Done',
                  onPressed: onDone,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small tinted line of copy — a warning, an error, or a neutral status.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// A file size in the SAME 1024 divisor the rest of the app formats with — the
/// server's ceilings are binary, and mixing the two makes a refusal look wrong.
String formatModelBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}
