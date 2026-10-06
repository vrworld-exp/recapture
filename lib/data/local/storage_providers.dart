// lib/data/local/storage_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'active_session_box.dart';
import 'config_cache_box.dart';
import 'level_intro_box.dart';
import 'offline_queue_box.dart';
import 'pending_capture_box.dart';
import 'projects_cache_box.dart';

/// Gateway to the resumable capture/project session box.
final activeSessionBoxProvider =
    Provider<ActiveSessionBox>((ref) => ActiveSessionBox());

/// Gateway to the cached projects list box.
final projectsCacheBoxProvider =
    Provider<ProjectsCacheBox>((ref) => ProjectsCacheBox());

/// Gateway to the cached remote capture-config box.
final configCacheBoxProvider =
    Provider<ConfigCacheBox>((ref) => ConfigCacheBox());

/// Gateway to the persisted offline action queue box.
final offlineQueueBoxProvider =
    Provider<OfflineQueueBox>((ref) => OfflineQueueBox());

/// Gateway to the per-intro "seen" / "don't show again" flags store.
final levelIntroStoreProvider =
    Provider<LevelIntroStore>((ref) => LevelIntroBox());

/// Gateway to the finished-captures-waiting-for-upload store. Read it only
/// through `pendingCapturesProvider` — that is the owner-filtered source of
/// truth the UI and the upload coordinator share.
final pendingCaptureStoreProvider =
    Provider<PendingCaptureStore>((ref) => HivePendingCaptureStore());
