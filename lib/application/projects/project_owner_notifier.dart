// lib/application/projects/project_owner_notifier.dart
//
// The two reads behind the ADMIN-only "Created by" label on a live project:
// the person's picture (drawn on every card) and their full identity (fetched
// when an admin actually opens the sheet).
//
// Both are plain FutureProviders because neither has state to mutate — nothing
// here writes. The interesting decisions are the CACHE LIFETIMES, and they are
// deliberately different:
//
//   • The picture is keyed by user id and kept for the session once it loads.
//     A live-projects list is usually a handful of prolific capturers, so the
//     same few faces scroll past again and again; an autoDispose that let go
//     the moment a row left the viewport would re-fetch the same image every
//     time it scrolled back.
//   • The IDENTITY is autoDispose and stays that way. It holds a RAW phone and
//     email — the one unmasked contact payload in this app — so it lives
//     exactly as long as the sheet showing it and is gone the moment that
//     closes. Keeping it warm to save a request would be trading the whole
//     point of the bound for a round trip nobody notices.
//
// Nothing here is persisted to Hive and nothing is logged. Same rule as the
// account snapshot: a contact detail is re-fetched, never stored.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/project_owner.dart';

/// The full identity behind a project, by owner id — name, role, RAW contact.
///
/// autoDispose WITHOUT a keepAlive, on purpose: see the note above. Opening the
/// same person twice costs two requests, and that is the intended trade.
final projectOwnerProvider =
    FutureProvider.autoDispose.family<ProjectOwnerDetail, String>(
  (ref, userId) => ref.watch(liveProjectsRepositoryProvider).owner(userId),
);

/// One owner's avatar bytes, by user id. Null means "no picture" — a normal
/// answer the label renders as initials, not a failure.
///
/// Kept alive for the session once it RESOLVES (including a resolved null:
/// re-asking whether someone still has no picture is the same wasted request).
/// A failure is deliberately not kept, so a picture that failed on a flaky
/// connection can load on the next scroll rather than staying blank until the
/// app restarts.
final projectOwnerAvatarProvider =
    FutureProvider.autoDispose.family<Uint8List?, String>((ref, userId) async {
  final bytes =
      await ref.watch(liveProjectsRepositoryProvider).ownerAvatarBytes(userId);
  ref.keepAlive();
  return bytes;
});
