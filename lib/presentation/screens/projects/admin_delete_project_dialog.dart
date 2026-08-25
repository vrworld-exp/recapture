// lib/presentation/screens/projects/admin_delete_project_dialog.dart
//
// The ADMIN "delete this live project" confirmation: pick SOFT (hide,
// recoverable) vs HARD (permanently erase photos + models), then type the
// project's exact name to arm the delete button.
//
// The name gate here is a courtesy only — the backend independently enforces
// `confirmName` (422 on mismatch), so a stale name or a race still cannot
// delete the wrong project. Material on both platforms deliberately: this is
// an internal staff tool, and a Cupertino action sheet cannot host the
// mode picker + text field this flow needs (unlike the simple count-based
// delete_confirmation_modal).
//
// DECOUPLED like the other confirm modals: it returns the chosen mode (or null
// on any dismissal) and performs no deletion itself — the caller acts on it.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/live_projects_repository.dart'
    show AdminDeleteMode;

/// Shows the two-mode delete confirmation for [projectName]. Resolves to the
/// confirmed [AdminDeleteMode], or null on cancel / tap-outside / system back.
Future<AdminDeleteMode?> showAdminDeleteProjectDialog(
  BuildContext context, {
  required String projectName,
}) {
  return showDialog<AdminDeleteMode>(
    context: context,
    barrierDismissible: true, // tap-outside == cancel
    barrierColor: AppColors.scrim,
    builder: (_) => _AdminDeleteDialog(projectName: projectName),
  );
}

class _AdminDeleteDialog extends StatefulWidget {
  const _AdminDeleteDialog({required this.projectName});

  final String projectName;

  @override
  State<_AdminDeleteDialog> createState() => _AdminDeleteDialogState();
}

class _AdminDeleteDialogState extends State<_AdminDeleteDialog> {
  AdminDeleteMode _mode = AdminDeleteMode.soft;
  final TextEditingController _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Re-arm/disarm the confirm button as the admin types.
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _nameMatches => _name.text.trim() == widget.projectName;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isHard = _mode == AdminDeleteMode.hard;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: Text('Delete this project?', style: text.titleMedium),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ModeOption(
              key: const ValueKey('admin_delete_mode_soft'),
              title: 'Soft delete',
              detail: 'Hide the project from everyone. Photos and models stay '
                  'in storage and the team can restore it.',
              selected: _mode == AdminDeleteMode.soft,
              onTap: () => setState(() => _mode = AdminDeleteMode.soft),
            ),
            const SizedBox(height: AppSpacing.sm),
            _ModeOption(
              key: const ValueKey('admin_delete_mode_hard'),
              title: 'Hard delete',
              detail: 'Permanently erase the project, its photos and its 3D '
                  'models. This cannot be undone.',
              selected: isHard,
              destructive: true,
              onTap: () => setState(() => _mode = AdminDeleteMode.hard),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Type the project name to confirm',
              style: text.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('admin_delete_confirm_field'),
              controller: _name,
              autofocus: false,
              style: text.bodyMedium,
              decoration: InputDecoration(
                hintText: widget.projectName,
                hintStyle:
                    text.bodyMedium?.copyWith(color: AppColors.textMuted),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          key: const ValueKey('admin_delete_confirm_cta'),
          // Armed only when the typed name matches — the backend re-checks.
          onPressed:
              _nameMatches ? () => Navigator.of(context).pop(_mode) : null,
          child: Text(
            isHard ? 'Delete forever' : 'Delete',
            style: TextStyle(
              color: _nameMatches ? AppColors.mirageRed : AppColors.disabled,
            ),
          ),
        ),
      ],
    );
  }
}

/// One selectable mode row: radio-style dot, title, and the consequence line.
class _ModeOption extends StatelessWidget {
  const _ModeOption({
    super.key,
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.destructive = false,
  });

  final String title;
  final String detail;
  final bool selected;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? AppColors.surface2 : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected
                    ? (destructive ? AppColors.mirageRed : AppColors.textPrimary)
                    : AppColors.textMuted,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.bodyMedium?.copyWith(
                        color: destructive
                            ? AppColors.mirageRed
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      detail,
                      style:
                          text.bodySmall?.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
