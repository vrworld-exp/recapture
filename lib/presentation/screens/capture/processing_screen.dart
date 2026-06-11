// lib/presentation/screens/capture/processing_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_scaffold.dart';

class ProcessingScreen extends StatelessWidget {
  const ProcessingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Processing', showBack: false),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.lg),
              Text("We'll update this automatically.", style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.xxxl),
              const _ProcessingStep(label: 'Queued', done: true, active: false),
              const _StepConnector(),
              const _ProcessingStep(label: 'Processing', done: true, active: false),
              const _StepConnector(),
              const _ProcessingStep(label: 'Texturing', done: false, active: true),
              const _StepConnector(),
              const _ProcessingStep(label: 'Optimizing', done: false, active: false),
              const _StepConnector(),
              const _ProcessingStep(label: 'Done', done: false, active: false),
              const SizedBox(height: AppSpacing.xxxl),
              Text('Last updated: just now',
                  style: tt.bodySmall?.copyWith(color: AppColors.textMuted)),
              const SizedBox(height: AppSpacing.xxl),
              AppCard(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Notify me when done', style: tt.bodyLarge),
                    Switch(
                      value: true,
                      thumbColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? AppColors.mirageRed
                            : AppColors.textMuted,
                      ),
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
              const Spacer(),
              AppButton.secondary(
                label: 'Back to Projects',
                onPressed: () => context.go(AppRoutes.projects),
              ),
              const SizedBox(height: AppSpacing.md),
              TextButton(
                onPressed: () => context.go(AppRoutes.modelReady),
                child: Text(
                  '→ Skip to Model Ready (skeleton nav)',
                  style: tt.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessingStep extends StatelessWidget {
  const _ProcessingStep({
    required this.label,
    required this.done,
    required this.active,
  });

  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: done
              ? const Icon(Icons.check_circle,
                  size: 24, color: AppColors.success)
              : active
                  ? const CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.mirageRed)
                  : Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.surface2,
                        border:
                            Border.all(color: AppColors.disabled, width: 0.5),
                      ),
                    ),
        ),
        const SizedBox(width: AppSpacing.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: active
                  ? const TextStyle(
                      fontSize: AppTypography.sizeBody,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mirageRed,
                    )
                  : done
                      ? tt.bodyLarge
                      : tt.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            if (active)
              Text('In progress…',
                  style: tt.bodySmall?.copyWith(color: AppColors.textMuted)),
          ],
        ),
      ],
    );
  }
}

class _StepConnector extends StatelessWidget {
  const _StepConnector();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 11),
      width: 2,
      height: 28,
      color: AppColors.disabled.withValues(alpha: 0.4),
    );
  }
}
