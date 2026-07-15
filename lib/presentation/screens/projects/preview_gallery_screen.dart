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
import '../../../application/projects/preview_download_service.dart';
import '../../../application/projects/preview_gallery_notifier.dart';
import '../../../data/repositories/live_projects_repository.dart';
import '../../../domain/entities/preview_manifest.dart';
import '../../widgets/app_button.dart';
import '../../widgets/delete_confirmation_modal.dart';

class PreviewGalleryScreen extends ConsumerStatefulWidget {
  const PreviewGalleryScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<PreviewGalleryScreen> createState() =>
      _PreviewGalleryScreenState();
}

class _PreviewGalleryScreenState extends ConsumerState<PreviewGalleryScreen> {
  /// Per-key download in-flight guard (mirrors the Live tab's _exportInFlight).
  final Set<String> _downloadInFlight = <String>{};

  /// Maps any Preview failure to friendly, mapped-only copy (never a raw
  /// code/URL) — same categories as the Live tab's _showFailure.
  static String failureCopy(Object error) => switch (error) {
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
        title: Text('Preview', style: Theme.of(context).textTheme.titleLarge),
      ),
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
                    return _PhotoTile(
                      key: ValueKey('preview_tile_${photo.key}'),
                      photo: photo,
                      onTap: () => _openViewer(manifest, photo),
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

/// One grid thumbnail with graceful loader/error placeholders.
class _PhotoTile extends StatelessWidget {
  const _PhotoTile({super.key, required this.photo, required this.onTap});

  final PreviewPhoto photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: AspectRatio(
          aspectRatio: 1,
          child: Image.network(
            photo.url,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const _TilePlaceholder(loading: true),
            errorBuilder: (_, __, ___) => const _TilePlaceholder(loading: false),
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
