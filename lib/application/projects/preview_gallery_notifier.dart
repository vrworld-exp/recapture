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
}

/// Preview gallery state for a given projectId. Auto-disposed when the screen
/// leaves so a second open re-fetches fresh (non-expired) URLs.
final previewGalleryProvider = AsyncNotifierProvider.family<
    PreviewGalleryNotifier, PreviewManifest, String>(
  PreviewGalleryNotifier.new,
);
