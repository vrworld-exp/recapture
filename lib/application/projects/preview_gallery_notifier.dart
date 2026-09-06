// lib/application/projects/preview_gallery_notifier.dart
//
// State for one open of the staff Preview gallery, keyed by projectId (family).
//
// Browsing is FREE: the gallery lists the capture set from
// `GET /admin/projects/:id/photos`, which mints no presigned urls and is not
// rate-limited. Tiles render through the authenticated photo-bytes proxy (see
// [AdminPhotoImage]), so opening, refreshing and scrolling the gallery cost
// nothing from the server's per-user export budget.
//
// The rate-limited export manifest is fetched only when a DOWNLOAD needs a real
// presigned url, and the result is cached here until it expires — so a session
// of downloads costs one token, not one per photo. (The gallery previously drew
// its thumbnails from that manifest, which is why ten opens exhausted a cap
// meant for ten exports.)
//
// Mutations:
//   • deletePhoto — soft-delete via the repo, then drop the tile LOCALLY (no
//     re-list: the server already agreed, and the local state is the truth the
//     grid renders). Throws on failure so the screen shows mapped copy and
//     keeps the tile.
//   • refresh     — an explicit user pull-to-refresh; re-lists, costs nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/preview_manifest.dart';

class PreviewGalleryNotifier
    extends FamilyAsyncNotifier<PreviewManifest, String> {
  /// The last export manifest, held until its urls expire. Only the download
  /// path fills this; browsing never touches it.
  PreviewManifest? _export;

  /// Presigned urls are treated as spent this long before their stated expiry,
  /// so a download started at the boundary can't race the clock.
  static const Duration _expiryMargin = Duration(seconds: 60);

  @override
  Future<PreviewManifest> build(String projectId) async {
    return _load(projectId);
  }

  Future<PreviewManifest> _load(String projectId) async {
    final photos = await ref.read(liveProjectsRepositoryProvider).photos(projectId);
    return PreviewManifest.fromPhotosMap(photos);
  }

  /// Soft-deletes [photo] and removes it from the in-memory list on success.
  /// Rethrows [LiveProjectsException] on failure (the tile stays put).
  Future<void> deletePhoto(PreviewPhoto photo) async {
    await ref.read(liveProjectsRepositoryProvider).deletePhotos(arg, [photo.key]);
    final cachedExport = _export;
    if (cachedExport != null) {
      // Keep the download cache honest rather than handing out a presigned url
      // for an object that has just been moved out of the capture set.
      _export = cachedExport.copyWithFiles(
        cachedExport.files.where((f) => f.key != photo.key).toList(),
      );
    }
    final current = state.valueOrNull;
    if (current == null) return;
    final next = current.files.where((f) => f.key != photo.key).toList();
    state = AsyncData(current.copyWithFiles(next));
  }

  /// Explicit user refresh — re-lists the capture set. Costs no rate-limit
  /// budget, so pull-to-refresh is a free action.
  Future<void> refresh() async {
    state = const AsyncLoading<PreviewManifest>().copyWithPrevious(state);
    state = await AsyncValue.guard(() => _load(arg));
  }

  /// Returns [photo] carrying a still-valid presigned download url.
  ///
  /// This is the ONLY path that spends the server's export budget. The minted
  /// manifest covers every photo in the set and is cached until it nears
  /// expiry, so downloading ten photos in one session costs one token; the
  /// eleventh, an hour later, costs a second. Returns the original [photo]
  /// (url-less) when its key is absent from the fresh manifest — e.g. deleted
  /// since — so the caller surfaces a mapped failure rather than crashing.
  Future<PreviewPhoto> freshPhotoFor(
    PreviewPhoto photo, {
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final manifest = _usableExport(clock) ?? await _loadExport();
    for (final f in manifest.files) {
      if (f.key == photo.key && f.url != null) return f;
    }
    return photo;
  }

  /// The cached export manifest while its urls are comfortably valid, else null.
  PreviewManifest? _usableExport(DateTime Function() clock) {
    final cached = _export;
    final expiresAt = cached?.expiresAt;
    if (cached == null || expiresAt == null) return null;
    return expiresAt.isAfter(clock().toUtc().add(_expiryMargin)) ? cached : null;
  }

  /// Mints a fresh export manifest (spends one rate-limit token) and caches it.
  Future<PreviewManifest> _loadExport() async {
    final export = await ref.read(liveProjectsRepositoryProvider).export(arg);
    final manifest = PreviewManifest.fromExportMap(export);
    _export = manifest;
    return manifest;
  }
}

/// Preview gallery state for a given projectId.
///
/// Kept alive for the app session (not autoDispose): re-opening a project's
/// gallery reuses the listing instead of re-fetching it. That is safe now in a
/// way it was not before — the listing holds no expiring credentials, so a
/// cached one cannot go stale into broken thumbnails the way a cached export
/// manifest could. Pull-to-refresh re-lists on demand.
final previewGalleryProvider = AsyncNotifierProvider.family<
    PreviewGalleryNotifier, PreviewManifest, String>(
  PreviewGalleryNotifier.new,
);
