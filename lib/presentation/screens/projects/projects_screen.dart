// lib/presentation/screens/projects/projects_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../domain/entities/project_status.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_status_pill.dart';

class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.bgPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Projects', style: tt.titleLarge),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined,
                color: AppColors.textSecondary),
            onPressed: () {},
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.mirageRed,
        onPressed: () => context.push(AppRoutes.createProject),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: const [
          _ProjectCard(
            name: 'Wooden Statue',
            status: ProjectStatus.completed,
            size: 'Small',
            updatedAt: '2h ago',
            action: 'View Model',
            tapRoute: AppRoutes.modelReady,
          ),
          SizedBox(height: AppSpacing.sm),
          _ProjectCard(
            name: 'Leather Chair',
            status: ProjectStatus.capturing,
            size: 'Medium',
            updatedAt: 'Today',
            action: 'Resume Capture',
            tapRoute: AppRoutes.preCapture,
          ),
          SizedBox(height: AppSpacing.sm),
          _ProjectCard(
            name: 'Coffee Mug',
            status: ProjectStatus.failed,
            size: 'Small',
            updatedAt: 'Yesterday',
            action: 'Retry',
            tapRoute: AppRoutes.captureSummary,
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
    required this.updatedAt,
    required this.action,
    required this.tapRoute,
  });

  final String name;
  final ProjectStatus status;
  final String size;
  final String updatedAt;
  final String action;
  final String tapRoute;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AppCard(
      onTap: () => context.go(tapRoute),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name, style: tt.headlineMedium),
              AppStatusPill(status: status),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  size,
                  style: const TextStyle(
                    fontSize: AppTypography.sizeLabel,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(updatedAt, style: tt.bodySmall),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Divider(
            color: AppColors.disabled.withValues(alpha: 0.5),
            thickness: 0.5,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                action,
                style: const TextStyle(
                  fontSize: AppTypography.sizeLabel,
                  fontWeight: FontWeight.w500,
                  color: AppColors.mirageRed,
                ),
              ),
              const Icon(Icons.arrow_forward_ios,
                  size: 12, color: AppColors.mirageRed),
            ],
          ),
        ],
      ),
    );
  }
}
