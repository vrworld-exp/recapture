// lib/presentation/widgets/project_options_sheet.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_options_result.dart';
import '../../domain/entities/project_status.dart';
import '../../utils/analytics.dart';
import 'app_button.dart';
import 'app_text_field.dart';
import 'offline_retry_modal.dart';

/// Presents the project options bottom sheet (Rename / Delete) for [project].
///
/// Always resolves to a [ProjectOptionsResult] — never null — so the caller can
/// branch deterministically. A swipe/back dismiss returns
/// [ProjectOptionsAction.none].
///
/// [onRename] and [onDelete] must throw on network failure; the sheet surfaces
/// the shared offline/retry modal and preserves the typed name on rename.
Future<ProjectOptionsResult> showProjectOptionsSheet(
  BuildContext context, {
  required Project project,
  required Future<Project> Function(String id, String newName) onRename,
  required Future<void> Function(String id) onDelete,
}) async {
  final result = await showModalBottomSheet<ProjectOptionsResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface1,
    barrierColor: AppColors.scrim,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (sheetContext) => _ProjectOptionsSheet(
      project: project,
      onRename: onRename,
      onDelete: onDelete,
    ),
  );
  return result ?? const ProjectOptionsResult.none();
}

enum _SheetMode { menu, rename }

class _ProjectOptionsSheet extends StatefulWidget {
  const _ProjectOptionsSheet({
    required this.project,
    required this.onRename,
    required this.onDelete,
  });

  final Project project;
  final Future<Project> Function(String id, String newName) onRename;
  final Future<void> Function(String id) onDelete;

  @override
  State<_ProjectOptionsSheet> createState() => _ProjectOptionsSheetState();
}

class _ProjectOptionsSheetState extends State<_ProjectOptionsSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.project.name);

  _SheetMode _mode = _SheetMode.menu;
  String? _nameError;

  /// In-flight guard for rename so a rapid double-tap fires only one request.
  bool _saving = false;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Rename ─────────────────────────────────────────────────────────────────

  void _enterRename() => setState(() {
        _mode = _SheetMode.rename;
        _nameError = null;
      });

  Future<void> _onSave() async {
    if (_saving) return;

    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = "Project name can't be empty");
      return;
    }
    // No change → treat Save as a no-op dismiss, no service call.
    if (name == widget.project.name.trim()) {
      Navigator.of(context).pop(const ProjectOptionsResult.none());
      return;
    }

    setState(() {
      _saving = true;
      _nameError = null;
    });

    Project? updated;
    try {
      updated = await widget.onRename(widget.project.id, name);
    } catch (_) {
      if (!mounted) return;
      // Offline modal retries the rename; it only returns once it succeeds,
      // so we capture the updated project from inside the retry closure.
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: () async {
          updated = await widget.onRename(widget.project.id, name);
        },
      );
    }

    if (!mounted) return;
    if (updated != null) {
      Analytics.logEvent('project_renamed', {
        'project_id': widget.project.id,
        'name_length': name.length,
        'device_type': _deviceType,
      });
      Navigator.of(context).pop(ProjectOptionsResult.renamed(updated!));
    } else {
      // Modal was a no-op (already showing) — leave the typed name intact.
      setState(() => _saving = false);
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    final didDelete = await showDialog<bool>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (_) => _DeleteConfirmDialog(
        projectName: widget.project.name,
        onDelete: () => widget.onDelete(widget.project.id),
      ),
    );
    if (!mounted || didDelete != true) return; // cancel / dismiss → no-op

    Analytics.logEvent('project_deleted', {
      'project_id': widget.project.id,
      'previous_status': widget.project.status.apiValue.toLowerCase(),
    });
    Navigator.of(context).pop(
      ProjectOptionsResult.deleted(widget.project.id),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        // Lift content above the keyboard when the rename field is focused.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: _mode == _SheetMode.menu
              ? _buildMenu(context)
              : _buildRename(context),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            widget.project.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        _OptionTile(
          icon: Icons.edit_outlined,
          label: 'Rename',
          onTap: _enterRename,
        ),
        _OptionTile(
          icon: Icons.delete_outline,
          label: 'Delete',
          color: AppColors.error,
          onTap: _confirmDelete,
        ),
      ],
    );
  }

  Widget _buildRename(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: Text(
            'Rename project',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        AppTextField(
          label: 'Project name',
          controller: _controller,
          errorText: _nameError,
          autofocus: true,
          enabled: !_saving,
          maxLength: kMaxProjectNameLength,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          onFieldSubmitted: (_) => _onSave(),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppButton.secondary(
                label: 'Cancel',
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context)
                        .pop(const ProjectOptionsResult.none()),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppButton(
                label: 'Save',
                isLoading: _saving,
                onPressed: _onSave,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A single tappable row in the options menu.
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Optional accent for destructive actions (defaults to neutral text).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.textPrimary;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      leading: Icon(icon, color: tint),
      title: Text(
        label,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: tint),
      ),
      onTap: onTap,
    );
  }
}

/// Destructive confirmation dialog. Owns the delete request, its in-flight
/// state, the double-tap guard, and offline-retry handling — it pops `true`
/// only after the delete actually succeeds.
class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({
    required this.projectName,
    required this.onDelete,
  });

  final String projectName;
  final Future<void> Function() onDelete;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  bool _deleting = false;

  Future<void> _onConfirm() async {
    if (_deleting) return;
    setState(() => _deleting = true);

    var ok = false;
    try {
      await widget.onDelete();
      ok = true;
    } catch (_) {
      if (!mounted) return;
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: () async {
          await widget.onDelete();
          ok = true;
        },
      );
    }

    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      title: Text(
        'Delete project?',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      content: Text(
        '"${widget.projectName}" will be permanently deleted. '
        "This can't be undone.",
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed:
              _deleting ? null : () => Navigator.of(context).pop(false),
          child: Text(
            'Cancel',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _onConfirm,
          child: _deleting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.error,
                  ),
                )
              : Text(
                  'Delete',
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: AppColors.error),
                ),
        ),
      ],
    );
  }
}
