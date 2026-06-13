// lib/presentation/screens/projects/projects_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/project_status.dart';
import '../../../platform/connectivity_watcher.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_status_pill.dart';
import '../../widgets/offline_retry_modal.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final ConnectivityWatcher _connectivity = ConnectivityWatcher();

  @override
  void initState() {
    super.initState();
    // Run the initial load after the first frame so a BuildContext is
    // available for the modal.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProjects());
  }

  /// Stand-in for the Projects API load until the backend lands. Until then
  /// connectivity is the data source — offline surfaces the retry modal.
  Future<void> _loadProjects() async {
    final status = await _connectivity.currentStatus();
    if (!mounted) return;
    if (status == AppConnectivityStatus.offline) {
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: _ensureOnline,
      );
    }
  }

  /// Throws while still offline so the modal stays open; returns on success so
  /// the modal auto-dismisses.
  Future<void> _ensureOnline() async {
    final status = await _connectivity.currentStatus();
    if (status == AppConnectivityStatus.offline) {
      throw const _OfflineException();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Projects', style: Theme.of(context).textTheme.titleLarge),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined, color: AppColors.textSecondary),
            onPressed: () {},
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push(AppRoutes.createProject),
        backgroundColor: AppColors.mirageRed,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _ProjectCard(
            name: 'Wooden Statue',
            status: ProjectStatus.completed,
            size: 'Small',
            updated: '2h ago',
            actionLabel: 'View Model',
            actionRed: false,
            onAction: () => context.go(AppRoutes.modelReady),
          ),
          const SizedBox(height: AppSpacing.sm),
          _ProjectCard(
            name: 'Leather Chair',
            status: ProjectStatus.capturing,
            size: 'Medium',
            updated: 'Today',
            actionLabel: 'Resume',
            actionRed: true,
            onAction: () => context.go(AppRoutes.preCapture),
          ),
          const SizedBox(height: AppSpacing.sm),
          _ProjectCard(
            name: 'Coffee Mug',
            status: ProjectStatus.failed,
            size: 'Small',
            updated: 'Yesterday',
            actionLabel: 'Retry',
            actionRed: false,
            onAction: () => context.go(AppRoutes.captureSummary),
          ),
        ],
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.name,
    required this.status,
    required this.size,
    required this.updated,
    required this.actionLabel,
    required this.actionRed,
    required this.onAction,
  });

  final String name;
  final ProjectStatus status;
  final String size;
  final String updated;
  final String actionLabel;
  final bool actionRed;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name, style: Theme.of(context).textTheme.bodyLarge),
              AppStatusPill(status: status),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              _Chip(label: size),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Updated $updated',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(color: AppColors.disabled, thickness: 0.5, height: 1),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: actionRed ? AppColors.mirageRed : AppColors.textPrimary,
                  padding: EdgeInsets.zero,
                ),
                child: Text(actionLabel),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: AppSpacing.md,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Raised when a load is attempted while the device is still offline.
class _OfflineException implements Exception {
  const _OfflineException();
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.disabled.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
