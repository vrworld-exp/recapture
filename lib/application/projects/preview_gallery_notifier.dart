// lib/application/projects/preview_gallery_notifier.dart
//
// State for one open of the staff Preview gallery, keyed by projectId (family).
// Loads the export manifest ONCE (the export endpoint is rate-limited and its
// presigned URLs expire ~1h), parses it to the typed [PreviewManifest], and
// owns two mutations:
//   • deletePhoto  — soft-delete via the repo, then drop the tile LOCALLY (no
//     manifest re-fetch: that would spend a rate-limit token and re-presign
//     everything). Throws on failure so the screen shows mapped copy and keeps
//     the tile.
//   • refresh      — an explicit user pull-to-refresh (costs a token by design).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/preview_manifest.dart';

class PreviewGalleryNotifier
    extends FamilyAsyncNotifier<PreviewManifest, String> {
  @override
  Future<PreviewManifest> build(String projectId) async {
    return _load(projectId);
  }

  Future<PreviewManifest> _load(String projectId) async {
    final export = await ref.read(liveProjectsRepositoryProvider).export(projectId);
    return PreviewManifest.fromExportMap(export);
  }

  /// Soft-deletes [photo] and removes it from the in-memory list on success.
  /// Rethrows [LiveProjectsException] on failure (the tile stays put).
  Future<void> deletePhoto(PreviewPhoto photo) async {
    await ref.read(liveProjectsRepositoryProvider).deletePhotos(arg, [photo.key]);
    final current = state.valueOrNull;
    if (current == null) return;
    final next = current.files.where((f) => f.key != photo.key).toList();
    state = AsyncData(current.copyWithFiles(next));
  }

  /// Explicit user refresh — re-fetches the manifest (spends a rate-limit token).
  Future<void> refresh() async {
    state = const AsyncLoading<PreviewManifest>().copyWithPrevious(state);
    state = await AsyncValue.guard(() => _load(arg));
  }

  /// Returns a [photo] guaranteed to carry a still-valid presigned url. The
  /// manifest is loaded once and its urls expire (~1h); if the current
  /// manifest is at/near expiry this re-fetches it (spending a rate-limit
  /// token) and returns the fresh entry for the same [PreviewPhoto.key]. When
  /// the url is still good — the common case — it returns [photo] untouched and
  /// spends nothing. Used by the Download action so a save never fails on (or
  /// silently writes) an expired url; matters especially on web, where the
  /// browser downloads the url directly with no chance to catch a 403.
  Future<PreviewPhoto> freshPhotoFor(PreviewPhoto photo, {DateTime Function()? now}) async {
    final clock = now ?? DateTime.now;
    final expiresAt = state.valueOrNull?.expiresAt;
    // Refresh when expiry is unknown or within a 60s safety margin of now.
    final stale = expiresAt == null ||
        !expiresAt.isAfter(clock().toUtc().add(const Duration(seconds: 60)));
    if (!stale) return photo;

    await refresh();
    for (final f in state.valueOrNull?.files ?? const <PreviewPhoto>[]) {
      if (f.key == photo.key) return f;
    }
    // The key vanished (e.g. deleted since) — fall back to the original so the
    // caller still attempts, and surfaces a mapped failure if the url is dead.
    return photo;
  }
}

/// Preview gallery state for a given projectId. Auto-disposed when the screen
/// leaves so a second open re-fetches fresh (non-expired) URLs.
final previewGalleryProvider = AsyncNotifierProvider.family<
    PreviewGalleryNotifier, PreviewManifest, String>(
  PreviewGalleryNotifier.new,
);
