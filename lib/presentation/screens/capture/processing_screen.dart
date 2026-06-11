// lib/presentation/screens/capture/processing_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key});

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  bool _notifyEnabled = true;
  Timer? _autoNavTimer;

  // 0=Queued, 1=Processing, 2=Texturing(active), 3=Optimizing, 4=Done
  static const _stages = ['Queued', 'Processing', 'Texturing', 'Optimizing', 'Done'];
  static const _currentStageIndex = 2;

  @override
  void initState() {
    super.initState();
    _autoNavTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) context.go(AppRoutes.modelReady);
    });
  }

  @override
  void dispose() {
    _autoNavTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Processing', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "We'll update this automatically.",
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxxl),
            ..._buildStepper(context),
            const SizedBox(height: AppSpacing.huge),
            Text(
              'Last updated: just now',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Notify me when done',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Switch(
                  value: _notifyEnabled,
                  onChanged: (v) => setState(() => _notifyEnabled = v),
                  activeThumbColor: AppColors.mirageRed,
                ),
              ],
            ),
            const Spacer(),
            AppButton.secondary(
              label: 'Back to Projects',
              onPressed: () => context.go(AppRoutes.projects),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildStepper(BuildContext context) {
    final widgets = <Widget>[];
    for (int i = 0; i < _stages.length; i++) {
      widgets.add(_StageRow(
        label: _stages[i],
        state: i < _currentStageIndex
            ? _StageState.completed
            : i == _currentStageIndex
                ? _StageState.active
                : _StageState.pending,
      ));
      if (i < _stages.length - 1) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 11),
          child: Container(
            width: 2,
            height: AppSpacing.xxxl,
            color: AppColors.disabled,
          ),
        ));
      }
    }
    return widgets;
  }
}

enum _StageState { completed, active, pending }

class _StageRow extends StatelessWidget {
  const _StageRow({required this.label, required this.state});

  final String label;
  final _StageState state;

  @override
  Widget build(BuildContext context) {
    Widget indicator;
    TextStyle? labelStyle;
    String? caption;

    switch (state) {
      case _StageState.completed:
        indicator = const Icon(Icons.check_circle, color: AppColors.success, size: 24);
        labelStyle = Theme.of(context).textTheme.bodyLarge;
        break;
      case _StageState.active:
        indicator = const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.mirageRed,
          ),
        );
        labelStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: AppColors.mirageRed,
              fontWeight: FontWeight.bold,
            );
        caption = 'In progress…';
        break;
      case _StageState.pending:
        indicator = Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.disabled),
          ),
        );
        labelStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.textMuted,
            );
        break;
    }

    return Row(
      children: [
        indicator,
        const SizedBox(width: AppSpacing.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: labelStyle),
            if (caption != null)
              Text(
                caption,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.mirageRed),
              ),
          ],
        ),
      ],
    );
  }
}
