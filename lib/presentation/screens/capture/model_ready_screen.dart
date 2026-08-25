// lib/presentation/screens/capture/model_ready_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class ModelReadyScreen extends StatelessWidget {
  const ModelReadyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Model Ready', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: AppSpacing.sm),
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
            onPressed: () => _showOptionsSheet(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ViewerMock(),
            Container(height: 1, color: AppColors.royalGold.withValues(alpha: 0.3)),
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  _InfoChip(label: 'v1'),
                  SizedBox(width: AppSpacing.sm),
                  _InfoChip(label: '18 MB'),
                  SizedBox(width: AppSpacing.sm),
                  _InfoChip(label: 'Updated today'),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Column(
                children: [
                  AppButton(
                    label: 'AR Preview',
                    icon: Icons.view_in_ar,
                    onPressed: () => context.push(AppRoutes.arPreview),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton.secondary(
                    label: 'Share Link',
                    icon: Icons.share_outlined,
                    onPressed: () {},
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton.secondary(
                    label: 'Re-capture',
                    icon: Icons.refresh,
                    onPressed: () => context.go(AppRoutes.preCapture),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Version History',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const _VersionRow(
                      label: 'v1 — Today, 18MB',
                      status: 'Completed',
                      dotColor: AppColors.success,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const _VersionRow(
                      label: 'v0 — Yesterday, 22MB',
                      status: 'Failed',
                      dotColor: AppColors.error,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  void _showOptionsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.md),
        ),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.error),
              title: const Text('Delete model',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.of(context).pop(),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined, color: AppColors.textSecondary),
              title: const Text('Download',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewerMock extends StatelessWidget {
  const _ViewerMock();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 280,
      color: AppColors.surface1,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            painter: _PerspectiveGridPainter(),
            child: const SizedBox.expand(),
          ),
          Icon(
            Icons.view_in_ar,
            size: 80,
            color: AppColors.mirageRed.withValues(alpha: 0.8),
          ),
          Positioned(
            bottom: AppSpacing.md,
            child: Text(
              'Tap to interact',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _PerspectiveGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.disabled.withValues(alpha: 0.15)
      ..strokeWidth = 0.5;
    final cx = size.width / 2;
    final cy = size.height / 2;
    for (int i = 0; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(cx, cy), paint);
      canvas.drawLine(Offset(x, size.height), Offset(cx, cy), paint);
    }
    for (int j = 1; j < 5; j++) {
      final r = j * size.height / 10;
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(_PerspectiveGridPainter old) => false;
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.label,
    required this.status,
    required this.dotColor,
  });

  final String label;
  final String status;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '$label, $status',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
