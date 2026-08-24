// lib/presentation/screens/projects/project_photos_screen.dart
//
// The artist photo grid for one UPLOAD project: the set that was uploaded,
// hand-picked down to 3–4, then Generate.
//
// ── NOT LINKED FROM THE HUB ANY MORE ────────────────────────────────────────
// Nothing navigates here: the project card no longer offers a picker of its
// own, because hand-picking now lives in ONE place for both sources — Preview →
// "Create Model" → pick 3–4 → "Create Model" (preview_gallery_screen.dart).
// Every photo route this screen calls is `requireRole('MODEL_ARTIST')`, so
// every upload-project owner is staff and can always reach that door; this
// screen is a second way to do the same thing, and two of them is how the two
// drift apart.
//
// It is kept, unlinked, rather than deleted: `/projects/:id/photos` still
// resolves for a deep link, and the deletion is a call to make deliberately —
// not a side effect of moving a button. Reaching for it as the destination of
// some NEW affordance is the mistake this note exists to stop; add that
// affordance to Preview instead.
//
// On success this routes to the EXISTING model screens — no new ones are built.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/project_photos_notifier.dart';
import '../../../data/repositories/project_photos_repository.dart';
import '../../widgets/app_button.dart';
import 'model_building_screen.dart';

class ProjectPhotosScreen extends ConsumerStatefulWidget {
  const ProjectPhotosScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectPhotosScreen> createState() => _ProjectPhotosScreenState();
}

class _ProjectPhotosScreenState extends ConsumerState<ProjectPhotosScreen> {
  @override
  void initState() {
    super.initState();
    // The notifier may already hold the set (the upload flow just filled it);
    // reloading is still correct, because a presigned URL expires within the
    // hour and a returning artist needs fresh ones.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(projectPhotosProvider.notifier).refreshPhotos(widget.projectId);
    });
  }

  Future<void> _generate() async {
    final notifier = ref.read(projectPhotosProvider.notifier);
    final modelId = await notifier.generate(widget.projectId);
    if (!mounted) return;
    if (modelId == null) {
      final message = ref.read(projectPhotosProvider).message;
      if (message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    // The EXISTING building screen owns the minutes-long half (it polls and
    // then opens the viewer). Nothing new is built for this path.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelBuildingScreen(
          projectId: widget.projectId,
          projectName: ref.read(projectPhotosProvider).project?.name ?? 'Project',
        ),
      ),
    );
    if (mounted) {
      await ref.read(projectPhotosProvider.notifier).refreshPhotos(widget.projectId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectPhotosProvider);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () => navigateBack(context),
        ),
        title: Text('Photos', style: theme.textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _hint(state),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ),
            ),
            Expanded(child: _body(state)),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                key: const Key('project_photos_generate'),
                label: 'Generate 3D model',
                isLoading: state.phase == PhotoUploadPhase.generating,
                onPressed: state.canGenerate ? _generate : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _hint(ProjectPhotosState state) {
    if (state.photos.isEmpty) return 'No photos in this project yet.';
    final n = state.selectedKeys.length;
    if (n < kMinSelectedPhotos) {
      return 'Select $kMinSelectedPhotos–$kMaxSelectedPhotos photos that show the '
          'object from different sides. ($n selected)';
    }
    return '$n of $kMaxSelectedPhotos selected.';
  }

  Widget _body(ProjectPhotosState state) {
    if (state.phase == PhotoUploadPhase.failed && state.photos.isEmpty) {
      return _Message(
        text: state.message ??
            photoUploadFallbackMessage(
              state.failure ?? PhotoUploadFailure.unknown,
            ),
        onRetry: () =>
            ref.read(projectPhotosProvider.notifier).refreshPhotos(widget.projectId),
      );
    }
    if (state.photos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
      ),
      itemCount: state.photos.length,
      itemBuilder: (_, i) {
        final photo = state.photos[i];
        return _PhotoTile(
          photo: photo,
          selected: state.selectedKeys.contains(photo.key),
          // A tap that would exceed the 3–4 bound is a no-op in the notifier,
          // so the UI never has to show an error for it — but the tile still
          // dims so the cap is visible rather than mysterious.
          atSelectionCap: state.selectedKeys.length >= kMaxSelectedPhotos &&
              !state.selectedKeys.contains(photo.key),
          onTap: state.isBusy
              ? null
              : () => ref
                  .read(projectPhotosProvider.notifier)
                  .toggleSelection(photo.key),
          onDelete: state.isBusy
              ? null
              : () => ref
                  .read(projectPhotosProvider.notifier)
                  .deletePhoto(widget.projectId, photo.key),
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.photo,
    required this.selected,
    required this.atSelectionCap,
    required this.onTap,
    required this.onDelete,
  });

  final ProjectPhoto photo;
  final bool selected;
  final bool atSelectionCap;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: atSelectionCap ? 0.45 : 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: Image.network(
                photo.url,
                fit: BoxFit.cover,
                // A presigned URL expires within the hour; an expired one
                // degrades to a placeholder rather than a broken-image glyph.
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.surface2,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_not_supported_outlined,
                      color: AppColors.textMuted, size: 20),
                ),
              ),
            ),
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  border: Border.all(color: AppColors.mirageRed, width: 3),
                ),
              ),
            Positioned(
              top: 2,
              left: 2,
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected ? AppColors.mirageRed : Colors.white70,
              ),
            ),
            if (onDelete != null)
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  iconSize: 16,
                  icon: const Icon(Icons.close, color: Colors.white),
                  // A soft delete server-side (moved to `deleted/`), never a
                  // hard one — the object stays recoverable.
                  onPressed: onDelete,
                  tooltip: 'Remove photo',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.md),
            AppButton.secondary(
              label: 'Try again',
              isFullWidth: false,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
