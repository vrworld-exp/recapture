// lib/presentation/screens/projects/preview_gallery_screen.dart
//
// Staff-only Preview gallery for one project: a grid of every captured photo of
// the project's exportable job, each openable full-screen with a Download
// (share-sheet) action and — for ADMIN only — a Delete (soft-delete) action, so
// staff can curate the set before/instead of a bulk export.
//
// Reuses the SAME rate-limited export manifest as the Export flow: the manifest
// is fetched ONCE per open (previewGalleryProvider) and each file's presigned
// url is used as BOTH the thumbnail source and the download URL. Errors show
// MAPPED copy only — never a raw code or URL (same rule as 9F / the Live tab).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/model_generation_notifier.dart';
import '../../../application/projects/preview_download_service.dart';
import '../../../application/projects/preview_gallery_notifier.dart';
import '../../../data/repositories/live_projects_repository.dart';
import '../../../domain/entities/preview_manifest.dart';
import '../../widgets/app_button.dart';
import '../../widgets/delete_confirmation_modal.dart';
import 'model_generation_screen.dart';

class PreviewGalleryScreen extends ConsumerStatefulWidget {
  const PreviewGalleryScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<PreviewGalleryScreen> createState() =>
      _PreviewGalleryScreenState();
}

/// Selection bounds for a Meshy generation. MIRRORS the server's authority
/// (projectModelsService MIN/MAX_SELECTED_PHOTOS) — the CTA gate here is a
/// courtesy so a staff user isn't sent to a guaranteed 400; the backend still
/// re-checks. Keep the two in sync.
const int kMinModelPhotos = 3;
const int kMaxModelPhotos = 4;

/// Maps any staff-surface failure to friendly, mapped-only copy (never a raw
/// code/URL) — same categories as the Live tab's _showFailure. Top-level so the
/// model history screen shares this one definition rather than paraphrasing it.
String failureCopy(Object error) => switch (error) {
      LiveProjectsException(failure: LiveProjectsFailure.notExportable) =>
        'This project has no finished upload to preview yet.',
      LiveProjectsException(failure: LiveProjectsFailure.rateLimited) =>
        'Preview limit reached — try again later.',
      LiveProjectsException(failure: LiveProjectsFailure.forbidden) =>
        'Your account no longer has staff access.',
      LiveProjectsException(failure: LiveProjectsFailure.network) =>
        'You’re offline — check your connection and try again.',
      _ => 'Something went wrong. Please try again.',
    };

class _PreviewGalleryScreenState extends ConsumerState<PreviewGalleryScreen> {
  /// Per-key download in-flight guard (mirrors the Live tab's _exportInFlight).
  final Set<String> _downloadInFlight = <String>{};

  /// Selection mode: tapping a tile picks it for model generation instead of
  /// opening the viewer. Off by default so the browse/download flow is unchanged.
  bool _selecting = false;

  /// The picked photos, by [PreviewPhoto.key] — the same relative key the
  /// server resolves against the job prefix.
  final Set<String> _selected = <String>{};

  bool _creating = false;

  bool get _canCreate =>
      _selected.length >= kMinModelPhotos && _selected.length <= kMaxModelPhotos;

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _toggle(PreviewPhoto photo) {
    setState(() {
      if (!_selected.remove(photo.key) && _selected.length < kMaxModelPhotos) {
        _selected.add(photo.key);
      }
    });
  }

  /// Requests a generation from the current selection and opens the status view.
  Future<void> _createModel() async {
    if (_creating || !_canCreate) return;
    setState(() => _creating = true);
    try {
      final model = await ref
          .read(modelGenerationProvider(widget.projectId).notifier)
          .createModel(
            _selected.toList(),
            // One key per selection attempt: a double-tap or a retried request
            // resolves to the SAME record server-side instead of paying for a
            // second generation.
            idempotencyKey: _idempotencyKeyFor(_selected),
          );
      if (!mounted) return;
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelGenerationScreen(
            projectId: widget.projectId,
            modelId: model.id,
          ),
        ),
      );
    } catch (e) {
      _snack(failureCopy(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// A stable key for one (project, selection) pair, so an accidental re-tap of
  /// the same selection replays rather than re-charges. Choosing a different
  /// set is a genuinely different request and gets a different key.
  String _idempotencyKeyFor(Set<String> keys) {
    final sorted = keys.toList()..sort();
    return '${widget.projectId}:${sorted.join('|')}'.hashCode.toRadixString(16);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _download(PreviewPhoto photo) async {
    if (_downloadInFlight.contains(photo.key)) return;
    setState(() => _downloadInFlight.add(photo.key));
    try {
      // The manifest's presigned urls expire (~1h) — refresh if stale so the
      // save (and, on web, the direct browser download) never hits a dead url.
      final fresh = await ref
          .read(previewGalleryProvider(widget.projectId).notifier)
          .freshPhotoFor(photo);
      await ref.read(previewDownloaderProvider).download(fresh);
      _snack('Saved ${fresh.fileName}');
    } catch (_) {
      // Never surface the presigned URL or a raw error.
      _snack('Couldn’t download this photo. Please try again.');
    } finally {
      if (mounted) setState(() => _downloadInFlight.remove(photo.key));
    }
  }

  /// Confirms, then soft-deletes [photo]; removes the tile locally on success.
  /// Returns true when the photo was deleted (so an open viewer can close).
  Future<bool> _delete(PreviewPhoto photo) async {
    final confirmed = await showDeleteConfirmation(context, count: 1);
    if (!confirmed || !mounted) return false;
    try {
      await ref
          .read(previewGalleryProvider(widget.projectId).notifier)
          .deletePhoto(photo);
      _snack('Photo deleted');
      return true;
    } catch (e) {
      _snack(failureCopy(e));
      return false;
    }
  }

  Future<void> _openViewer(PreviewManifest manifest, PreviewPhoto photo) async {
    final canDelete = ref.read(isAdminProvider);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _PhotoViewer(
          photo: photo,
          canDelete: canDelete,
          isDownloading: () => _downloadInFlight.contains(photo.key),
          onDownload: () => _download(photo),
          onDelete: () async {
            final deleted = await _delete(photo);
            if (deleted && mounted) Navigator.of(context).maybePop();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(previewGalleryProvider(widget.projectId));
    // The screen is already staff-only, but the CTA spends Meshy credits — gate
    // it on the role too rather than relying on the route alone.
    final canCreateModel = ref.watch(isStaffProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
          tooltip: 'Back',
          // go()-replaced flow screen: funnel BACK through the shared handler so
          // hardware back / this arrow both return to Projects, never the OS home.
          onPressed: () => navigateBack(context),
        ),
        title: Text(
          _selecting ? 'Select photos' : 'Preview',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        actions: [
          if (canCreateModel && (async.valueOrNull?.files.isNotEmpty ?? false))
            TextButton(
              key: const ValueKey('preview_select_toggle'),
              onPressed: _toggleSelecting,
              child: Text(_selecting ? 'Cancel' : 'Create Model'),
            ),
        ],
      ),
      bottomNavigationBar: _selecting ? _createModelBar(context) : null,
      body: async.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.mirageRed),
        ),
        error: (error, __) => _PreviewErrorView(
          message: failureCopy(error),
          onRetry: () => ref.invalidate(previewGalleryProvider(widget.projectId)),
        ),
        data: (manifest) => _body(manifest),
      ),
    );
  }

  /// The Create Model CTA + its live selection hint. Disabled outside the 3–4
  /// bound, with the hint saying WHY rather than leaving a dead button.
  Widget _createModelBar(BuildContext context) {
    final n = _selected.length;
    final hint = switch (n) {
      < kMinModelPhotos => 'Select $kMinModelPhotos–$kMaxModelPhotos photos '
          'from different angles ($n selected)',
      _ => '$n of $kMaxModelPhotos selected',
    };
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hint,
              key: const ValueKey('create_model_hint'),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              key: const ValueKey('create_model_cta'),
              label: 'Create Model',
              icon: Icons.auto_awesome,
              isLoading: _creating,
              onPressed: _canCreate ? _createModel : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(PreviewManifest manifest) {
    return RefreshIndicator(
      color: AppColors.mirageRed,
      backgroundColor: AppColors.surface1,
      // Explicit re-fetch (spends a rate-limit token) — the user asked for it.
      onRefresh: () =>
          ref.read(previewGalleryProvider(widget.projectId).notifier).refresh(),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _Header(manifest: manifest)),
          if (manifest.files.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyView(),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final photo = manifest.files[index];
                    final selected = _selected.contains(photo.key);
                    return _PhotoTile(
                      key: ValueKey('preview_tile_${photo.key}'),
                      photo: photo,
                      selectable: _selecting,
                      selected: selected,
                      // In selection mode a tap picks instead of opening — the
                      // grid is the picker, so a second surface would just be
                      // in the way.
                      onTap: () => _selecting
                          ? _toggle(photo)
                          : _openViewer(manifest, photo),
                    );
                  },
                  childCount: manifest.files.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Header: file count + a subtle "links expire at HH:MM" note (same expiry
/// formatting as the Live tab's export snackbar).
class _Header extends StatelessWidget {
  const _Header({required this.manifest});

  final PreviewManifest manifest;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppColors.textMuted);
    final expiry = manifest.expiresAt;
    final expiryNote = expiry == null
        ? null
        : 'Links expire at ${TimeOfDay.fromDateTime(expiry.toLocal()).format(context)}';
    final drift = manifest.fileCount < manifest.expectedFileCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            manifest.fileCount == 1
                ? '1 photo'
                : '${manifest.fileCount} photos'
                    '${drift ? ' of ${manifest.expectedFileCount}' : ''}',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (expiryNote != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(expiryNote, style: muted),
          ],
        ],
      ),
    );
  }
}

/// One grid thumbnail with graceful loader/error placeholders. In selection
/// mode it also carries the checkmark + dimming that show what is picked.
class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.photo,
    required this.onTap,
    this.selectable = false,
    this.selected = false,
  });

  final PreviewPhoto photo;
  final VoidCallback onTap;
  final bool selectable;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                photo.url,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const _TilePlaceholder(loading: true),
                errorBuilder: (_, __, ___) =>
                    const _TilePlaceholder(loading: false),
              ),
              if (selectable)
                _SelectionOverlay(
                  key: ValueKey('preview_tile_check_${photo.key}'),
                  selected: selected,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The selected/unselected affordance drawn over a tile in selection mode.
class _SelectionOverlay extends StatelessWidget {
  const _SelectionOverlay({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: selected
            ? Border.all(color: AppColors.mirageRed, width: 3)
            : null,
        // Unselected tiles recede so the picked set reads at a glance.
        color: selected ? null : Colors.black.withValues(alpha: 0.35),
      ),
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            size: 20,
            color: selected ? AppColors.mirageRed : Colors.white70,
            semanticLabel: selected ? 'Selected' : 'Not selected',
          ),
        ),
      ),
    );
  }
}

class _TilePlaceholder extends StatelessWidget {
  const _TilePlaceholder({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.textMuted),
            )
          : const Icon(Icons.broken_image_outlined,
              color: AppColors.textMuted, size: 22),
    );
  }
}

/// Full-screen viewer for one photo with Download + (admin) Delete actions.
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.photo,
    required this.canDelete,
    required this.isDownloading,
    required this.onDownload,
    required this.onDelete,
  });

  final PreviewPhoto photo;
  final bool canDelete;
  final bool Function() isDownloading;
  final VoidCallback onDownload;
  final Future<void> Function() onDelete;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Text(
          widget.photo.fileName,
          style: Theme.of(context).textTheme.bodyMedium,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: InteractiveViewer(
                child: Image.network(
                  widget.photo.url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const _TilePlaceholder(loading: true),
                  errorBuilder: (_, __, ___) =>
                      const _TilePlaceholder(loading: false),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Download',
                      icon: Icons.download_outlined,
                      isLoading: widget.isDownloading(),
                      onPressed: widget.onDownload,
                    ),
                  ),
                  if (widget.canDelete) ...[
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: AppButton.secondary(
                        label: 'Delete',
                        icon: Icons.delete_outline,
                        onPressed: () => widget.onDelete(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
            const Icon(Icons.photo_library_outlined,
                color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No photos to preview.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewErrorView extends StatelessWidget {
  const _PreviewErrorView({required this.message, required this.onRetry});

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
