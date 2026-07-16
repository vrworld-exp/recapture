// lib/presentation/screens/projects/model_viewer_screen.dart
//
// Renders one generated 3D model (GLB) with orbit controls + AR where the
// device supports it, badged with its ORIGIN ("Created by Meshy AI").
//
// The badge is driven by [ProjectModelView.source], never inferred — an origin
// this build doesn't know renders unbadged rather than mis-attributing.
//
// The URL is always OUR CloudFront one (the backend re-hosts Meshy's expiring
// results), so it is safe to hold for the life of the screen. It is still a
// URL we never surface on screen: a load failure shows mapped copy only, the
// same rule as the Preview gallery / 9F.
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';

/// Builds the widget that actually renders [glbUrl]. Injectable so tests can
/// exercise the screen's chrome (badge, approve bar) without a webview
/// platform — [ModelViewer] drives a real WebView under the hood, which has no
/// implementation registered in a widget test.
typedef ModelRenderBuilder = Widget Function(BuildContext context, String glbUrl);

class ModelViewerScreen extends StatelessWidget {
  const ModelViewerScreen({
    super.key,
    required this.model,
    this.title = '3D Model',
    this.onApprove,
    this.renderBuilder = _defaultRenderBuilder,
  });

  final ProjectModelView model;
  final String title;

  /// Staff-only "we're satisfied — skip manual creation" action. Null hides it
  /// (the owner's viewer).
  final Future<void> Function()? onApprove;

  /// How the GLB is rendered. Defaults to the real orbit/AR viewer.
  final ModelRenderBuilder renderBuilder;

  static Widget _defaultRenderBuilder(BuildContext context, String glbUrl) {
    return ModelViewer(
      key: const ValueKey('model_viewer'),
      src: glbUrl,
      alt: 'A 3D model of the captured object',
      ar: true,
      autoRotate: true,
      cameraControls: true,
      disableZoom: false,
      backgroundColor: AppColors.bgPrimary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final glbUrl = model.glbUrl;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      body: glbUrl == null
          // Defensive: the CTA is only shown for a viewable model, so this is a
          // programming error rather than a user-facing state.
          ? const _ModelUnavailable()
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: renderBuilder(context, glbUrl)),
                      if (model.source.badgeLabel case final label?)
                        Positioned(
                          left: AppSpacing.lg,
                          top: AppSpacing.lg,
                          child: _OriginBadge(label: label),
                        ),
                    ],
                  ),
                ),
                if (onApprove != null)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: _ApproveBar(
                        approved: model.approved,
                        onApprove: onApprove!,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The origin attribution overlaid on the model.
class _OriginBadge extends StatelessWidget {
  const _OriginBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface2.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, size: 14, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ApproveBar extends StatefulWidget {
  const _ApproveBar({required this.approved, required this.onApprove});

  final bool approved;
  final Future<void> Function() onApprove;

  @override
  State<_ApproveBar> createState() => _ApproveBarState();
}

class _ApproveBarState extends State<_ApproveBar> {
  bool _busy = false;

  Future<void> _approve() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onApprove();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.approved) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle, size: 18, color: AppColors.mirageRed),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Approved — no manual model needed',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      );
    }
    return AppButton(
      key: const ValueKey('model_approve_cta'),
      label: 'Approve this model',
      icon: Icons.check,
      isLoading: _busy,
      onPressed: _approve,
    );
  }
}

class _ModelUnavailable extends StatelessWidget {
  const _ModelUnavailable();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_in_ar_outlined,
                color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'This model isn’t available to view yet.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
