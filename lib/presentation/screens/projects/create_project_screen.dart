// lib/presentation/screens/projects/create_project_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_text_field.dart';

class CreateProjectScreen extends StatefulWidget {
  const CreateProjectScreen({super.key});

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  String _selectedSize = 'Small';
  bool _guidedSelected = true;

  static const _sizes = ['Small', 'Medium', 'Large'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
        title: Text('New Project', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionLabel('PROJECT NAME'),
                  const SizedBox(height: AppSpacing.sm),
                  const AppTextField(label: 'Project name', hint: 'e.g. Wooden statue'),
                  const SizedBox(height: AppSpacing.xxl),
                  const _SectionLabel('OBJECT SIZE'),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Size helps us guide camera distance.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: _sizes
                        .map((s) => Padding(
                              padding: const EdgeInsets.only(right: AppSpacing.sm),
                              child: _SizeChip(
                                label: s,
                                selected: _selectedSize == s,
                                onTap: () => setState(() => _selectedSize = s),
                              ),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  const _SectionLabel('CAPTURE MODE'),
                  const SizedBox(height: AppSpacing.md),
                  _ModeCard(
                    title: 'Guided',
                    subtitle: 'Step-by-step with quality checks',
                    selected: _guidedSelected,
                    onTap: () => setState(() => _guidedSelected = true),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _ModeCard(
                    title: 'Manual',
                    subtitle: 'You control shots (advanced)',
                    selected: !_guidedSelected,
                    onTap: () => setState(() => _guidedSelected = false),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: AppButton(
              label: 'Create & Start',
              onPressed: () => context.go(AppRoutes.preCapture),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.textSecondary,
            letterSpacing: 0.08,
          ),
    );
  }
}

class _SizeChip extends StatelessWidget {
  const _SizeChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.sm + 2),
        decoration: BoxDecoration(
          color: selected ? AppColors.mirageRed : AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: selected
              ? null
              : Border.all(color: AppColors.disabled.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: selected ? Colors.white : AppColors.textSecondary,
              ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (selected)
            Container(
              width: AppSpacing.sm,
              height: AppSpacing.sm,
              decoration: const BoxDecoration(
                color: AppColors.mirageRed,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}
