// lib/application/upload/upload_prefs_provider.dart
//
// "Upload on mobile data" (offline capture, Step B3): defaults to OFF, persisted
// on the device, toggled from Profile. Read by the pending-upload coordinator
// through [autoUploadSettingsProvider].
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/upload_prefs_box.dart';
import '../../domain/upload/auto_upload_policy.dart';

final uploadPrefsStoreProvider =
    Provider<UploadPrefsStore>((ref) => UploadPrefsBox());

final uploadOnMobileDataProvider =
    NotifierProvider<UploadOnMobileDataNotifier, bool>(
  UploadOnMobileDataNotifier.new,
);

class UploadOnMobileDataNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false; // OFF until the stored value says otherwise
  }

  Future<void> _load() async {
    final stored =
        await ref.read(uploadPrefsStoreProvider).getUploadOnMobileData();
    if (stored != null && stored != state) state = stored;
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    await ref.read(uploadPrefsStoreProvider).setUploadOnMobileData(enabled);
  }
}

/// The settings snapshot the auto-upload policy reads.
final autoUploadSettingsProvider = Provider<AutoUploadSettings>(
  (ref) => AutoUploadSettings(
    uploadOnMobileData: ref.watch(uploadOnMobileDataProvider),
  ),
);
