// lib/presentation/screens/projects/preview_gallery_screen.dart
//
// Staff-only Preview gallery for one project: a grid of every captured photo of
// the project's exportable job, each openable full-screen with a Download
// (share-sheet) action and — for ADMIN only — a Delete (soft-delete) action, so
// staff can curate the set before/instead of a bulk export.
//
// The full-screen view is a PAGER over the whole set (swipe / edge arrows /
// arrow keys — see [_PhotoViewer]), not a single photo: judging a capture means
// comparing it with the ones either side of it, and bouncing back to the grid
// between every pair is how a set of thirty stops getting looked at.
//
// BROWSING COSTS NOTHING. The grid is listed from the credential-free
// `/photos` endpoint and every pixel is drawn through the authenticated
// photo-bytes proxy ([AdminPhotoImage]). Only Download reaches for the export
// manifest, and its notifier caches that until it expires. This screen used to
// draw its thumbnails from presigned export urls, so ten opens spent a budget
// meant for ten real exports and the gallery started refusing to load. Do not
// reintroduce a presigned url as an image source.
//
// PREVIEWING IS UNLIMITED — on the server as well. The export manifest's
// per-user window is off by default (`ADMIN_EXPORT_MAX_PER_WINDOW=0`), so a
// staff user downloading from the eleventh project in an hour is not refused
// either. There is no "preview limit" left to report, which is why the 429
// copy below no longer claims one: the only windows still reachable from these
// surfaces guard real spend (Create Model, Optimize), and a 429 from those is
// worded as what it is.
//
// Errors show MAPPED copy only — never a raw code or URL (same rule as 9F /
// the Live tab).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/model_generation_notifier.dart';
import '../../../application/projects/preview_download_service.dart';
import '../../../application/projects/preview_gallery_notifier.dart';
import '../../../data/remote/admin_photo_image.dart';
import '../../../data/remote/api_client.dart';
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

/// Server-side downscale width for a grid thumbnail. The grid is 3 columns, so
/// a tile is well under 512 px even at a high DPR — asking for the original
/// would stream full-resolution captures through the proxy to paint them into
/// a ~125 dp square.
const int kPreviewThumbWidth = 512;

/// Downscale width for the full-screen viewer: generous enough for
/// pinch-to-zoom inspection, still bounded so opening one photo isn't a
/// multi-megabyte transfer. Download always delivers the untouched original.
const int kPreviewViewerWidth = 2048;

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
      // Never "Preview limit": previewing photos and models is unlimited, and
      // a 429 here comes from an ACTION window (Create Model / Optimize). Say
      // when to retry if the server told us, so the user isn't left guessing.
      LiveProjectsException(
        failure: LiveProjectsFailure.rateLimited,
        retryAfterSeconds: final retry
      ) =>
        retry == null
            ? 'Too many requests right now — try again in a few minutes.'
            : 'Too many requests right now — try again in ${friendlyWait(retry)}.',
      LiveProjectsException(failure: LiveProjectsFailure.forbidden) =>
        'Your account no longer has staff access.',
      LiveProjectsException(failure: LiveProjectsFailure.network) =>
        'You’re offline — check your connection and try again.',
      // The row the button was on is out of date — retrying the same request
      // would fail identically, so the copy asks for a refresh instead.
      LiveProjectsException(failure: LiveProjectsFailure.notOptimizable) =>
        'This model can’t be optimized — pull down to refresh the list.',
      _ => 'Something went wrong. Please try again.',
    };

/// "$n seconds" under a minute and a half, else whole minutes — the same
/// rounding the Live tab uses for its retry hints.
String friendlyWait(int seconds) {
  if (seconds < 90) return '$seconds seconds';
  return '${(seconds / 60).ceil()} minutes';
}

class _PreviewGalleryScreenState extends ConsumerState<PreviewGalleryScreen> {
  /// Sizing-only override for the app-bar CTA: everything visual (fill,
  /// border, radius, text style, disabled states) still resolves from the
  /// elevated/outlined button themes, so this can never drift off-theme.
  static final ButtonStyle _appBarCompact = ElevatedButton.styleFrom(
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
  );

  /// Per-key download in-flight guard (mirrors the Live tab's _exportInFlight).
  final Set<String> _downloadInFlight = <String>{};

  /// Selection mode: tapping a tile picks it for model generation instead of
  /// opening the viewer. Off by default so the browse/download flow is unchanged.
  bool _selecting = false;

  /// The picked photos, by [PreviewPhoto.key] — the same relative key the
  /// server resolves against the job prefix.
  final Set<String> _selected = <String>{};

  /// Create-Model in-flight guard. The press spends Meshy credits, so a fast
  /// double-tap must not fire a second request before the first lands (the
  /// server's idempotency key is the backstop, this is the front one).
  bool _creating = false;

  bool get _canCreate =>
      _selected.length >= kMinModelPhotos &&
      _selected.length <= kMaxModelPhotos;

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

  /// A stable key for one (project, keys) request: a double-tap resolves to the
  /// SAME record server-side instead of a second PAID generation.
  String _idempotencyKeyFor(List<String> keys) {
    final sorted = [...keys]..sort();
    return '${widget.projectId}:${sorted.join('|')}'.hashCode.toRadixString(16);
  }

  /// Sends the selected photos to Maya AI and opens the generation screen.
  Future<void> _createModel() async {
    if (!_canCreate || _creating) return;
    // Walk the MANIFEST and filter, never the Set: selection order is request
    // order, and a Set has none — the photo order reaching Meshy would be
    // arbitrary.
    final keys = [
      for (final photo in ref
              .read(previewGalleryProvider(widget.projectId))
              .valueOrNull
              ?.files ??
          const <PreviewPhoto>[])
        if (_selected.contains(photo.key)) photo.key,
    ];
    if (keys.length < kMinModelPhotos) return;

    setState(() => _creating = true);
    try {
      final model = await ref
          .read(modelGenerationProvider(widget.projectId).notifier)
          .createModel(keys, idempotencyKey: _idempotencyKeyFor(keys));
      if (!mounted) return;
      // Cleared only on SUCCESS — a failed create must leave the picked photos
      // alone so a retry doesn't start with re-picking them.
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
      // A dialog, not a snackbar: this press spends credits and a toast that
      // fades in four seconds is how a real failure gets reported as "nothing
      // happened".
      if (mounted) await _showCreateFailure(failureCopy(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Mapped copy only — never a raw error, code or URL.
  Future<void> _showCreateFailure(String message) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('create_model_error'),
          title: const Text('Couldn’t start the model'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

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

  /// The authenticated proxy-backed image for [photo] at [width] px. Every
  /// pixel the gallery shows comes through here — never a presigned url, whose
  /// minting is what the export rate limit protects.
  AdminPhotoImage _imageFor(PreviewPhoto photo, int width) => AdminPhotoImage(
        dio: ref.read(dioProvider),
        projectId: widget.projectId,
        photoKey: photo.key,
        maxWidth: width,
      );

  /// Opens the full-screen viewer at [index] of the capture set.
  ///
  /// An INDEX, not a photo: the viewer pages across the whole set, so where in
  /// it the tap landed is the thing worth passing. The list itself is watched
  /// inside the viewer rather than snapshotted here, so a delete made in there
  /// lands on the next photo instead of stranding the pager on a tile the grid
  /// no longer has.
  Future<void> _openViewer(int index) async {
    final canDelete = ref.read(isAdminProvider);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _PhotoViewer(
          projectId: widget.projectId,
          initialIndex: index,
          canDelete: canDelete,
          imageFor: (photo) => _imageFor(photo, kPreviewViewerWidth),
          onDownload: _download,
          onDelete: _delete,
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
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Center(
                // Same design language as every other CTA (AppButton primary /
                // secondary), just compacted for an app-bar slot: colors,
                // shape and typography come from the button THEMES; only the
                // sizing is overridden (AppButton itself can't sit here — its
                // theme minimumSize is infinite-width × 48).
                child: _selecting
                    ? OutlinedButton(
                        key: const ValueKey('preview_select_toggle'),
                        style: _appBarCompact,
                        onPressed: _toggleSelecting,
                        child: const Text('Cancel'),
                      )
                    : ElevatedButton.icon(
                        key: const ValueKey('preview_select_toggle'),
                        style: _appBarCompact,
                        onPressed: _toggleSelecting,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('Create Model'),
                      ),
              ),
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
          onRetry: () =>
              ref.invalidate(previewGalleryProvider(widget.projectId)),
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
              onPressed: (_canCreate && !_creating) ? _createModel : null,
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
      // Re-lists the capture set; mints no presigned urls, so refreshing is free.
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
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                      image: _imageFor(photo, kPreviewThumbWidth),
                      selectable: _selecting,
                      selected: selected,
                      // In selection mode a tap picks instead of opening — the
                      // grid is the picker, so a second surface would just be
                      // in the way.
                      onTap: () => _selecting
                          ? _toggle(photo)
                          : _openViewer(index),
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
    required this.image,
    required this.onTap,
    this.selectable = false,
    this.selected = false,
  });

  final PreviewPhoto photo;

  /// Proxy-backed thumbnail source (see [AdminPhotoImage]) — the tile never
  /// holds a url of its own.
  final ImageProvider image;

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
              Image(
                image: image,
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
        border:
            selected ? Border.all(color: AppColors.mirageRed, width: 3) : null,
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

/// Full-screen viewer for the capture set: opened at one photo, pageable
/// across every other photo of the same project, with Download + (admin)
/// Delete acting on whichever one is on screen.
///
/// THREE ways to move, because the two builds do not share an input. A SWIPE
/// (a finger on the apk; a mouse drag on web, which needs
/// [_DragAnywhereScrollBehavior] — Flutter does not let a mouse drag a
/// scrollable by default, so the gesture would silently do nothing there), the
/// on-screen ARROWS at either edge, and the LEFT/RIGHT keyboard keys a browser
/// user reaches for first. All three drive the one [PageController], so there
/// is no second notion of "which photo" to drift out of step.
///
/// The photo list is WATCHED, not passed in: deleting the photo on screen
/// shrinks the set underneath the pager, which is exactly what makes it land on
/// the next photo. Only an emptied set closes the viewer.
class _PhotoViewer extends ConsumerStatefulWidget {
  const _PhotoViewer({
    required this.projectId,
    required this.initialIndex,
    required this.canDelete,
    required this.imageFor,
    required this.onDownload,
    required this.onDelete,
  });

  final String projectId;

  /// Where the tapped tile sat in the set at open time.
  final int initialIndex;

  final bool canDelete;

  /// Proxy-backed full-view source for one photo (see [AdminPhotoImage]).
  /// Download resolves its own presigned url separately and delivers the
  /// untouched original.
  final ImageProvider Function(PreviewPhoto) imageFor;

  final Future<void> Function(PreviewPhoto) onDownload;

  /// Confirms, then soft-deletes; true when the photo is gone.
  final Future<bool> Function(PreviewPhoto) onDelete;

  @override
  ConsumerState<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<_PhotoViewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);

  late int _index = widget.initialIndex;

  /// Per-photo download guard held HERE as well as in the gallery: the viewer
  /// is its own route, so a setState in the gallery does not rebuild it and the
  /// button would spin only on the screen nobody is looking at.
  final Set<String> _downloading = <String>{};

  /// True while the photo on screen is zoomed in. Paging is suspended then, so
  /// a drag pans the photo instead of flicking to the next one.
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int index, int count) {
    if (index < 0 || index >= count || index == _index) return;
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(KeyEvent event, int count) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goTo(_index - 1, count);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goTo(_index + 1, count);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _download(PreviewPhoto photo) async {
    if (_downloading.contains(photo.key)) return;
    setState(() => _downloading.add(photo.key));
    try {
      await widget.onDownload(photo);
    } finally {
      if (mounted) setState(() => _downloading.remove(photo.key));
    }
  }

  Future<void> _delete(PreviewPhoto photo) async {
    final deleted = await widget.onDelete(photo);
    if (!deleted || !mounted) return;
    // The watched set has already lost it, so the pager is showing a neighbour.
    // Closing is right only when there is no neighbour left to show.
    final remaining = ref
            .read(previewGalleryProvider(widget.projectId))
            .valueOrNull
            ?.files
            .length ??
        0;
    if (remaining == 0) await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final files =
        ref.watch(previewGalleryProvider(widget.projectId)).valueOrNull?.files ??
            const <PreviewPhoto>[];
    // Nothing left to page over. _delete is already closing the route; this is
    // just the frame in between.
    if (files.isEmpty) {
      return const Scaffold(backgroundColor: AppColors.bgPrimary);
    }
    // Deleting the LAST photo of the set leaves the index past its end.
    if (_index > files.length - 1) {
      _index = files.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpToPage(_index);
      });
    }
    final photo = files[_index];
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              photo.fileName,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
            // Position is the thing a pager owes the viewer: without it there
            // is no way to tell a long set from a stuck one.
            if (files.length > 1)
              Text(
                '${_index + 1} of ${files.length}',
                key: const ValueKey('preview_viewer_counter'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
          ],
        ),
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, event) => _onKey(event, files.length),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  ScrollConfiguration(
                    behavior: const _DragAnywhereScrollBehavior(),
                    child: PageView.builder(
                      key: const ValueKey('preview_viewer_pager'),
                      controller: _controller,
                      physics: _zoomed
                          ? const NeverScrollableScrollPhysics()
                          : const PageScrollPhysics(),
                      itemCount: files.length,
                      onPageChanged: (i) => setState(() {
                        _index = i;
                        // The page arriving is at rest; whatever the one
                        // leaving was zoomed to is not this page's state.
                        _zoomed = false;
                      }),
                      itemBuilder: (_, i) => _ZoomablePhoto(
                        key: ValueKey('preview_page_${files[i].key}'),
                        image: widget.imageFor(files[i]),
                        onZoomChanged: (zoomed) {
                          if (zoomed != _zoomed && i == _index) {
                            setState(() => _zoomed = zoomed);
                          }
                        },
                      ),
                    ),
                  ),
                  // Hidden rather than disabled at the ends: a dead arrow on a
                  // photo reads as a broken one.
                  if (_index > 0)
                    _NavArrow(
                      buttonKey: const ValueKey('preview_viewer_prev'),
                      alignment: Alignment.centerLeft,
                      icon: Icons.chevron_left,
                      tooltip: 'Previous photo',
                      onPressed: () => _goTo(_index - 1, files.length),
                    ),
                  if (_index < files.length - 1)
                    _NavArrow(
                      buttonKey: const ValueKey('preview_viewer_next'),
                      alignment: Alignment.centerRight,
                      icon: Icons.chevron_right,
                      tooltip: 'Next photo',
                      onPressed: () => _goTo(_index + 1, files.length),
                    ),
                ],
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
                        isLoading: _downloading.contains(photo.key),
                        onPressed: () => _download(photo),
                      ),
                    ),
                    if (widget.canDelete) ...[
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppButton.secondary(
                          label: 'Delete',
                          icon: Icons.delete_outline,
                          onPressed: () => _delete(photo),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One edge arrow over the photo: a thumb target on the apk, the obvious mouse
/// affordance on web. Sits on a scrim so it stays visible over a pale capture.
class _NavArrow extends StatelessWidget {
  const _NavArrow({
    required this.buttonKey,
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Material(
          color: AppColors.scrim,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            key: buttonKey,
            tooltip: tooltip,
            iconSize: 28,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(icon, color: AppColors.textPrimary),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}

/// One page of the viewer: the photo, zoomable for inspection. It reports its
/// zoom state up so the pager can stop competing with a pan.
class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({
    super.key,
    required this.image,
    required this.onZoomChanged,
  });

  final ImageProvider image;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> {
  final TransformationController _transform = TransformationController();

  @override
  void initState() {
    super.initState();
    _transform.addListener(_report);
  }

  /// A hair above 1, so float noise from a settled pinch does not read as zoom
  /// and leave the pager permanently stuck.
  void _report() =>
      widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.01);

  @override
  void dispose() {
    _transform.removeListener(_report);
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InteractiveViewer(
        transformationController: _transform,
        child: Image(
          image: widget.image,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const _TilePlaceholder(loading: true),
          errorBuilder: (_, __, ___) => const _TilePlaceholder(loading: false),
        ),
      ),
    );
  }
}

/// Lets a MOUSE drag the pager. Flutter allows dragging a scrollable with touch
/// and stylus only, so without this the swipe works on the apk and does nothing
/// at all on web — where most staff open this gallery.
class _DragAnywhereScrollBehavior extends MaterialScrollBehavior {
  const _DragAnywhereScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      };
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
