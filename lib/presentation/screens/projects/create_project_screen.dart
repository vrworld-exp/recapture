// lib/presentation/screens/projects/create_project_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/app_text_field.dart';

class CreateProjectScreen extends StatelessWidget {
  const CreateProjectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'New Project'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.xxl),
              _sectionLabel('PROJECT NAME'),
              const SizedBox(height: AppSpacing.sm),
              const AppTextField(
                label: 'Project name',
                hint: 'e.g. Wooden statue',
              ),
              const SizedBox(height: AppSpacing.xxl),
              _sectionLabel('OBJECT SIZE'),
              const SizedBox(height: AppSpacing.xs),
              Text('Size helps us guide camera distance.',
                  style: tt.bodySmall?.copyWith(color: AppColors.textMuted)),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _sizeSelectChip('Small', selected: true),
                  const SizedBox(width: AppSpacing.sm),
                  _sizeSelectChip('Medium', selected: false),
                  const SizedBox(width: AppSpacing.sm),
                  _sizeSelectChip('Large', selected: false),
                ],
              ),
              const SizedBox(height: AppSpacing.xxl),
              _sectionLabel('CAPTURE MODE'),
              const SizedBox(height: AppSpacing.md),
              AppCard(
                child: Row(
                  children: [
                    const Icon(Icons.auto_fix_high,
                        color: AppColors.mirageRed, size: 20),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Guided', style: tt.headlineMedium),
                          Text('Step-by-step with quality checks',
                              style: tt.bodySmall),
                        ],
                      ),
                    ),
                    const Icon(Icons.radio_button_checked,
                        color: AppColors.mirageRed, size: 20),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Row(
                  children: [
                    const Icon(Icons.tune,
                        color: AppColors.textMuted, size: 20),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Manual',
                              style: tt.headlineMedium?.copyWith(
                                  color: AppColors.textSecondary)),
                          Text('You control shots (advanced)',
                              style: tt.bodySmall),
                        ],
                      ),
                    ),
                    const Icon(Icons.radio_button_unchecked,
                        color: AppColors.disabled, size: 20),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xxxl),
              AppButton(
                label: 'Create & Start',
                onPressed: () => context.go(AppRoutes.preCapture),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _sectionLabel(String label) {
  return Text(
    label,
    style: const TextStyle(
      fontSize: AppTypography.sizeLabel,
      fontWeight: FontWeight.w500,
      color: AppColors.textSecondary,
      letterSpacing: 0.08,
    ),
  );
}

Widget _sizeSelectChip(String label, {required bool selected}) {
  return Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        color: selected ? AppColors.mirageRed : AppColors.surface2,
        border: selected
            ? null
            : Border.all(color: AppColors.disabled, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppTypography.sizeLabel,
          fontWeight: FontWeight.w500,
          color: selected ? Colors.white : AppColors.textSecondary,
        ),
        textAlign: TextAlign.center,
      ),
    ),
  );
}
