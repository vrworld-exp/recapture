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
//
// The app-bar Export action is gated INSIDE the screen on isStaffProvider
// (ADMIN + MODEL_ARTIST) rather than at each call site — the owner's push in
// projects_screen and any future caller are covered for free, and the owner
// can never see it. Delivery goes through the modelExporterProvider seam
// (platform-split, tests inject a fake).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/model_export_service.dart';
import '../../../application/projects/model_generation_notifier.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import 'model_render_view.dart';
import 'preview_gallery_screen.dart' show failureCopy;

/// Builds the widget that actually renders [model] (its GLB, plus the USDZ
/// for iOS AR when present). Injectable so tests can exercise the screen's
/// chrome (badge, approve bar) without a webview platform — the real renderer
/// drives a WebView under the hood, which has no implementation registered in
/// a widget test.
typedef ModelRenderBuilder = Widget Function(
    BuildContext context, ProjectModelView model);

class ModelViewerScreen extends StatelessWidget {
  const ModelViewerScreen({
    super.key,
    required this.model,
    this.title = '3D Model',
    this.onApprove,
    this.onRegenerate,
    this.onOptimize,
    this.renderBuilder = defaultRenderBuilder,
  });

  final ProjectModelView model;
  final String title;

  /// Shrinks this model into an OPT variant. Null hides the action; so does a
  /// model whose [ProjectModelView.canOptimize] is false — the SERVER's
  /// verdict, never a size rule re-derived here.
  ///
  /// Reached by BOTH audiences, always through their own route: the owner's
  /// caller wires it to the owner-scoped endpoint, staff to the admin one. The
  /// viewer itself never picks — it only renders the action it was handed.
  final Future<void> Function()? onOptimize;

  /// Staff-only "we're satisfied — skip manual creation" action. Null hides it
  /// (the owner's viewer).
  final Future<void> Function()? onApprove;

  /// Owner-facing "make a new version of this model" action. Null hides it
  /// (the staff viewer, which regenerates via Prepare-Images instead). Shown as
  /// a bottom action when there is no approve bar — the two never coexist.
  final VoidCallback? onRegenerate;

  /// How the model is rendered. Defaults to the real orbit/AR viewer
  /// ([ModelRenderView]: load/error states + the "View in your space" CTA).
  final ModelRenderBuilder renderBuilder;

  static Widget defaultRenderBuilder(
      BuildContext context, ProjectModelView model) {
    return ModelRenderView(model: model);
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
        actions: [
          // The ACTION. Outlined and labelled so it reads as a button, never
          // as the OPT state chip overlaid on the model below.
          if (glbUrl != null && model.canOptimize && onOptimize != null)
            _ViewerOptimizeButton(onOptimize: onOptimize!),
          // Staff-only (gated inside the button); nothing to export without
          // a GLB, so the unavailable body gets no dead action.
          if (glbUrl != null) _ExportButton(model: model),
        ],
      ),
      body: glbUrl == null
          // Defensive: the CTA is only shown for a viewable model, so this is a
          // programming error rather than a user-facing state.
          ? const ModelUnavailable()
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: renderBuilder(context, model)),
                      // An auto-generated model announces its QUALITY, not its
                      // vendor. "Created by Meshy AI" answers a question the
                      // owner never asked; "preview quality" tells them how
                      // much to trust what they're looking at — which is the
                      // difference between a disappointing product and a
                      // pleasant surprise. Staff/manual models keep the origin
                      // attribution.
                      // An OPT model has no origin of its own to attribute
                      // (ModelSource.optimized.badgeLabel is null by design) —
                      // what it has is a STATE, and that is what this says.
                      if (model.isOptimized)
                        const Positioned(
                          left: AppSpacing.lg,
                          top: AppSpacing.lg,
                          child: _OriginBadge(
                            key: ValueKey('model_optimized_badge'),
                            label: 'Optimized for fast loading',
                            icon: Icons.compress,
                          ),
                        )
                      else if ((model.isAutoGenerated
                              ? kAutoGeneratedBadgeLabel
                              : model.source.badgeLabel)
                          case final label?)
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
                  )
                // Owner-only "make a new version" — never alongside the staff
                // approve bar. Each tap is a deliberate new (capped) generation.
                else if (onRegenerate != null)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: AppButton.secondary(
                        key: const ValueKey('model_regenerate_cta'),
                        label: 'Create a new version',
                        icon: Icons.auto_awesome_outlined,
                        onPressed: onRegenerate,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The app-bar "Export model" action: saves the model file into the user's
/// system via the [modelExporterProvider] seam. Visible ONLY to staff
/// (ADMIN / MODEL_ARTIST) — watched here, not passed in, so every caller of
/// [ModelViewerScreen] is gated identically and the owner never sees it.
/// With both formats available it asks which one; a GLB-only model exports
/// straight away.
class _ExportButton extends ConsumerStatefulWidget {
  const _ExportButton({required this.model});

  final ProjectModelView model;

  @override
  ConsumerState<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends ConsumerState<_ExportButton> {
  bool _busy = false;

  ModelExportFile _file(String url, String ext, String mimeType) =>
      ModelExportFile(
        url: url,
        fileName: 'recapture-model-${widget.model.id}.$ext',
        mimeType: mimeType,
      );

  Future<void> _export(ModelExportFile file) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(modelExporterProvider).export(file);
    } catch (_) {
      // Mapped copy only — never the URL or the raw error (gallery/9F rule).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Couldn’t export this model. Please try again.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onPressed() async {
    final glbUrl = widget.model.glbUrl;
    if (glbUrl == null) return; // never built without one; defensive.
    final glb = _file(glbUrl, 'glb', 'model/gltf-binary');

    final usdzUrl = widget.model.usdzUrl;
    if (usdzUrl == null) {
      await _export(glb);
      return;
    }
    final choice = await showModalBottomSheet<ModelExportFile>(
      context: context,
      backgroundColor: AppColors.surface1,
      barrierColor: AppColors.scrim,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'Export model',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListTile(
              key: const ValueKey('model_export_glb'),
              leading: const Icon(Icons.view_in_ar_outlined,
                  color: AppColors.textSecondary),
              title: const Text('GLB'),
              subtitle: const Text('Universal 3D format — Blender, Unity, web'),
              onTap: () => Navigator.of(sheetContext).pop(glb),
            ),
            ListTile(
              key: const ValueKey('model_export_usdz'),
              leading: const Icon(Icons.phone_iphone,
                  color: AppColors.textSecondary),
              title: const Text('USDZ'),
              subtitle: const Text('Apple AR format — Quick Look on iPhone/iPad'),
              onTap: () => Navigator.of(sheetContext)
                  .pop(_file(usdzUrl, 'usdz', 'model/vnd.usdz+zip')),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (choice != null) await _export(choice);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(isStaffProvider)) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('model_export_btn'),
      tooltip: 'Export model',
      onPressed: _busy ? null : _onPressed,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.textSecondary),
            )
          : const Icon(Icons.download_outlined),
    );
  }
}

/// The app-bar "Optimize" action — available wherever a model is open, so a
/// model reached by deep link or straight from the project card can be
/// optimized without first going back out to a list.
///
/// Goes disabled with a spinner while in flight, and reports only MAPPED copy
/// on failure: the server's 409 reasons are internal rule ids.
class _ViewerOptimizeButton extends StatefulWidget {
  const _ViewerOptimizeButton({required this.onOptimize});

  final Future<void> Function() onOptimize;

  @override
  State<_ViewerOptimizeButton> createState() => _ViewerOptimizeButtonState();
}

class _ViewerOptimizeButtonState extends State<_ViewerOptimizeButton> {
  bool _busy = false;

  Future<void> _optimize() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.onOptimize();
      messenger.showSnackBar(const SnackBar(
        content: Text('Optimizing — we’ll have a smaller version shortly.'),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(failureCopy(error))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: OutlinedButton.icon(
        key: const ValueKey('model_optimize_cta'),
        onPressed: _busy ? null : _optimize,
        icon: _busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.textMuted),
              )
            : const Icon(Icons.compress, size: 16),
        label: const Text('Optimize'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          visualDensity: VisualDensity.compact,
          textStyle: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// The origin (or state) attribution overlaid on the model.
class _OriginBadge extends StatelessWidget {
  const _OriginBadge({
    super.key,
    required this.label,
    this.icon = Icons.auto_awesome,
  });

  final String label;
  final IconData icon;

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
          Icon(icon, size: 14, color: AppColors.textMuted),
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

/// Route entry for the staff viewer: resolves ONE model by id out of the
/// project's generation history and hands it to [ModelViewerScreen].
///
/// Resolves by id rather than taking the entity through `extra` for two
/// reasons: a cold deep-link (no extra) and a normal push then travel the SAME
/// path, so there is no null branch to get wrong; and approving re-renders from
/// the notifier's updated record instead of a stale snapshot captured at push
/// time. Watching the (already-polling) family provider adds no second loop —
/// pushed from the history it simply keeps the existing subscription alive.
class ModelViewerRoute extends ConsumerWidget {
  const ModelViewerRoute({
    super.key,
    required this.projectId,
    required this.modelId,
    this.renderBuilder,
  });

  final String projectId;
  final String modelId;

  /// Injectable for tests — the real [ModelViewer] drives a WebView, which has
  /// no platform implementation in a widget test.
  final ModelRenderBuilder? renderBuilder;

  static ProjectModelView? _find(List<ProjectModelView>? models, String id) {
    for (final m in models ?? const <ProjectModelView>[]) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(modelGenerationProvider(projectId));
    final canApprove = ref.watch(isStaffProvider);

    if (async.isLoading && !async.hasValue) {
      return const _ViewerScaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.mirageRed)),
      );
    }
    final model = _find(async.valueOrNull, modelId);
    // A stale link, a deleted record, or one that never produced a GLB — all
    // dead ends the user can arrive at legitimately, so none of them may crash
    // or show a blank viewer.
    if (model == null || !model.isViewable) {
      return const _ViewerScaffold(body: ModelUnavailable());
    }
    return ModelViewerScreen(
      model: model,
      renderBuilder: renderBuilder ?? ModelViewerScreen.defaultRenderBuilder,
      onApprove: canApprove
          ? () => ref
              .read(modelGenerationProvider(projectId).notifier)
              .approve(model.id)
          : null,
      // Staff reach this viewer from the history list, which already has its
      // own Optimize button — but a model opened directly (deep link, or from
      // the project detail) would otherwise have no way to it. The notifier's
      // refresh puts the new OPT row into the list either way.
      onOptimize: canApprove
          ? () => ref
              .read(modelGenerationProvider(projectId).notifier)
              .optimize(model.id)
          : null,
    );
  }
}

/// The viewer's chrome without a model — keeps the loading/unavailable states
/// looking like the screen they stand in for (title + a working back arrow).
class _ViewerScaffold extends StatelessWidget {
  const _ViewerScaffold({required this.body});

  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Text('3D Model', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: body,
    );
  }
}

/// The "nothing to render" body — a record that failed, is still generating, or
/// simply isn't there. Shared with [ModelViewerRoute], which reaches the same
/// dead end from a stale link rather than a programming error.
class ModelUnavailable extends StatelessWidget {
  const ModelUnavailable({super.key});

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
