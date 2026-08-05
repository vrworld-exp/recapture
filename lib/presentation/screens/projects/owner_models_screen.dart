// lib/presentation/screens/projects/owner_models_screen.dart
//
// Every 3D model a project has produced, for its OWNER — the screen that turns
// "here is your model" into "here are your models, pick one".
//
// Why it exists: the owner surface only ever showed the newest finished run
// (`GET /projects/:id`'s `model`). But a regenerate is not guaranteed to be an
// improvement — the photo selector picks different frames and Meshy is
// generative, so version 2 can genuinely be worse than version 1. With one slot
// there was no way for the owner to see that, let alone go back. This lists all
// of them, newest first, so they can open each and judge.
//
// The STAFF counterpart is [ModelHistoryScreen], and the two are deliberately
// different screens rather than one role-switched one: staff read the admin
// history route (403 for an owner) and see FAILED attempts, photo counts and
// both renditions of every model. None of that belongs here. An owner sees only
// models they can open.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/owner_models_provider.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import 'model_building_screen.dart' show ModelBuildingScreen;
import 'model_viewer_screen.dart';

class OwnerModelsScreen extends ConsumerWidget {
  const OwnerModelsScreen({
    super.key,
    required this.projectId,
    required this.projectName,
    this.onRegenerate,
    this.onOpenModel,
  });

  final String projectId;

  /// Shown as the viewer's title, so an opened model still says which project
  /// it belongs to.
  final String projectName;

  /// "Make a new version" — passed straight through to the viewer, which is
  /// where the owner is when they decide the model isn't good enough. Null
  /// hides it.
  final VoidCallback? onRegenerate;

  /// Overrides what a row's tap does. Mirrors [ModelBuildingScreen.onOpenViewer]
  /// and exists for the same reason: the real viewer drives a WebView, which has
  /// no platform implementation in a widget test, so a test asserting WHICH
  /// model a row opens has to intercept it here.
  final void Function(ProjectModelView model)? onOpenModel;

  void _open(BuildContext context, ProjectModelView model) {
    if (onOpenModel case final override?) {
      override(model);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(
          model: model,
          title: projectName,
          onRegenerate: onRegenerate,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ownerModelsProvider(projectId));
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Text('Your models', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: async.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.mirageRed),
        ),
        error: (_, __) => _ModelsErrorView(
          // Mapped copy only — the owner surface never renders a raw error, a
          // status code or a URL (same rule as 9F and the model viewer).
          message: "We couldn't load your models. Please try again.",
          onRetry: () => ref.invalidate(ownerModelsProvider(projectId)),
        ),
        data: (models) => models.isEmpty
            ? const _EmptyView()
            : Column(
                children: [
                  // Two rows with the SAME timestamp is the first thing an owner
                  // notices here, and it looks like a bug until it is explained.
                  if (_hasBothRenditions(models)) const _RenditionNote(),
                  Expanded(
                    child: RefreshIndicator(
                      color: AppColors.mirageRed,
                      backgroundColor: AppColors.surface1,
                      onRefresh: () =>
                          ref.refresh(ownerModelsProvider(projectId).future),
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        // Server order is newest-first, and served-rendition-
                        // first within a generation. Authoritative.
                        itemCount: models.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.sm),
                        itemBuilder: (context, index) {
                          final model = models[index];
                          return _OwnerModelRow(
                            // Keyed by id AND variant: one generation appears as
                            // TWO rows sharing an id (the original and the
                            // optimized build), and duplicate sibling keys are a
                            // Flutter error.
                            key: ValueKey(
                                'owner_model_row_${model.id}_${model.variant.name}'),
                            model: model,
                            // "Serving" only means something when there is a
                            // CHOICE — the staff history's rule, and the reason
                            // a lone model gets no label. Two extra conditions
                            // the staff screen doesn't need: the rendition must
                            // be the active one, AND it must belong to the
                            // NEWEST generation, since an older generation's
                            // active rendition is served nowhere.
                            isServing: models.length > 1 &&
                                model.id == models.first.id &&
                                model.isActiveVariant,
                            // A model whose web build is still running is
                            // openable but would serve bytes we are about to
                            // replace — the heavy original that often fails to
                            // load. Inert until it settles.
                            onTap: model.isSettled
                                ? () => _open(context, model)
                                : null,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Whether any generation in [models] appears as more than one rendition.
///
/// A property of the LIST, not of a row: two entries can share an `id` (the
/// original build and the optimized one), and it is that pairing — not any
/// single row — that needs explaining.
bool _hasBothRenditions(List<ProjectModelView> models) {
  final seen = <String>{};
  for (final model in models) {
    if (!seen.add(model.id)) return true;
  }
  return false;
}

/// One line explaining why a generation shows up twice.
///
/// Without it the list reads as duplicated rows with the same timestamp, which
/// looks like a bug and makes the choice between them arbitrary.
class _RenditionNote extends StatelessWidget {
  const _RenditionNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              // The badge is a three-letter abbreviation, so the one thing this
              // note must do is say what it stands for.
              'A model can have two versions. The one marked OPT is optimized '
              'to load faster on your phone; the other is the full-detail '
              'build. Open both to compare.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// One rendition of one finished model: when it was made, which build it is,
/// what it weighs, and a way in.
class _OwnerModelRow extends StatelessWidget {
  const _OwnerModelRow({
    super.key,
    required this.model,
    required this.isServing,
    this.onTap,
  });

  final ProjectModelView model;

  /// Whether to mark this row as the one the project actually loads. Only set
  /// when there is more than one to choose between — see the call site.
  final bool isServing;

  /// Null while the model is still being finished — the chevron follows it, so
  /// the affordance can't promise something the tap won't do.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              _RowThumbnail(previewUrl: model.previewUrl),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _stamp(model.createdAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                        ),
                        // Which BUILD this is — the answer to "why are there
                        // two rows with the same timestamp?". Badged on the
                        // OPTIMIZED row only, exactly like the staff history:
                        // the original is the baseline, and badging both would
                        // double the ink for a one-bit distinction.
                        if (model.variant.badgeLabel case final label?) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _Pill(label: label),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      _detail(model, isServing),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (onTap == null)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textMuted,
                  ),
                )
              else
                const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// The secondary line: size first, because with two rows for one generation
  /// the weight IS the difference — "318 KB" next to "7.92 MB" says more than
  /// any badge can. Then which one is being served, then the quality caveat: an
  /// auto-generated model is a preview, not a finished product.
  static String _detail(ProjectModelView model, bool isServing) {
    if (!model.isSettled) return 'Finishing up — this takes a moment.';
    final parts = <String>[
      if (model.metrics case final m?) m.sizeLabel,
      if (isServing) 'Serving',
      if (model.isAutoGenerated) 'AI generated' else 'Made for you',
      if (model.approved) 'Approved',
      // The unbadged build is the heavy one the OPT build exists to replace —
      // on many phones it is the "We couldn't load this model" build. Saying so
      // before the tap beats an unexplained failure after it. Owner-only: staff
      // read that off the triangle count.
      // if (model.variant == ModelVariant.original && !model.isActiveVariant)
      //   'May not load on every phone',
    ];
    return parts.join(' · ');
  }

  /// Compact local "Aug 5, 11:42". Hand-rolled: the app has no `intl`
  /// dependency, and one date format does not justify adding it.
  static String _stamp(DateTime? at) {
    if (at == null) return 'Model';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = at.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${months[local.month - 1]} ${local.day}, $hh:$mm';
  }
}

/// The model's poster image when the pipeline produced one; a neutral
/// placeholder otherwise, so every row is the same shape.
class _RowThumbnail extends StatelessWidget {
  const _RowThumbnail({required this.previewUrl});

  final String? previewUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: 56,
        height: 56,
        child: previewUrl == null
            ? const _ThumbPlaceholder()
            : Image.network(
                previewUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
              ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: const Icon(Icons.view_in_ar_outlined, color: AppColors.textMuted, size: 22),
    );
  }
}

/// Gold, not red: red is the CTA colour and this is a label, not an action.
class _Pill extends StatelessWidget {
  const _Pill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.royalGold.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.royalGold,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

/// Reachable only if a model existed when the list was opened and none does
/// now — rare, but a blank screen would read as a failure.
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_in_ar_outlined, color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No models yet.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelsErrorView extends StatelessWidget {
  const _ModelsErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Retry',
              icon: Icons.refresh,
              isFullWidth: false,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
