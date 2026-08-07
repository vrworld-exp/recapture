// lib/data/datasources/avatar_image_picker.dart
//
// Picks ONE profile picture from the device gallery, already downscaled and
// re-encoded, and decides its content type from the file's own bytes.
//
// PERMISSIONS: deliberately NOT routed through the app's native permission
// channel (data/datasources/platform/). Android 13+ reaches the system photo
// picker with no runtime permission at all, and iOS's limited-library picker
// likewise returns a file without a prompt in the common case; the
// NSPhotoLibraryUsageDescription already in ios/Runner/Info.plist covers the
// case where iOS does ask. Adding a READ_MEDIA_IMAGES gate here would ask for a
// permission the picker does not need.
//
// GALLERY ONLY in v1. The camera is a bespoke native pipeline in this app, so
// wiring it in as an avatar source is a separate decision, not a parameter.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../dev/dev_log/dev_upload_log.dart';
import '../../domain/entities/avatar_upload_failure.dart';

/// One picked avatar: the image BYTES and the content type those bytes say
/// they are.
///
/// Bytes, not a `dart:io` File, because this runs on WEB too. There the picker
/// returns an [XFile] wrapping a `blob:` URL — no path on any filesystem — so
/// `File(xfile.path)` compiles and then throws `UnsupportedError` the moment it
/// is read. Reading through [XFile] is the one API that behaves on every
/// platform. An avatar is small enough that holding it in memory is free.
class PickedAvatar {
  const PickedAvatar({required this.bytes, required this.contentType});

  final Uint8List bytes;

  /// `image/jpeg` or `image/png` — sniffed, never inferred from the extension.
  final String contentType;

  int get length => bytes.length;
}

/// Gallery picker seam. An interface so the Profile screen's tests can drive
/// the pick without a platform channel.
abstract interface class AvatarImagePicker {
  /// Opens the system gallery picker. Returns null when the user CANCELS —
  /// a silent no-op, not an error.
  ///
  /// Throws [AvatarUploadException] with
  /// [AvatarUploadFailure.unsupportedType] when the chosen file is not a JPEG
  /// or PNG, so the user finds out before anything is uploaded.
  Future<PickedAvatar?> pickAvatar();

  /// Reclaims a selection Android PARKED when it destroyed our activity while
  /// the gallery was in front — see [ImagePickerAvatarSource.recoverLostAvatar].
  /// Null when there is nothing to reclaim (and always, off Android).
  Future<PickedAvatar?> recoverLostAvatar();
}

class ImagePickerAvatarSource implements AvatarImagePicker {
  const ImagePickerAvatarSource([this._picker = const _DefaultPicker()]);

  final AvatarPickerBackend _picker;

  /// The longest edge of a stored avatar. It is rendered in a 96px ring, so
  /// 512 is already generous for a 3x display and keeps the upload small enough
  /// that the 2 MiB server ceiling is never in play on a real photo.
  ///
  /// NATIVE ONLY. `image_picker_for_web` ignores maxWidth/maxHeight/imageQuality
  /// — it has no native encoder to resize with — so a web pick arrives at its
  /// ORIGINAL dimensions and weight. That is why the server's byte ceiling has
  /// to be a real, user-visible failure rather than a formality: on web it is
  /// genuinely reachable.
  static const int maxDimension = 512;

  /// JPEG re-encode quality. 85 is the usual visually-lossless-enough point.
  static const int quality = 85;

  @override
  Future<PickedAvatar?> pickAvatar() async {
    // maxWidth/maxHeight/imageQuality resize and re-encode NATIVELY — that is
    // the whole reason this needs no `image` package (and no isolate).
    var picked = await _picker.pick(
      maxWidth: maxDimension,
      maxHeight: maxDimension,
      imageQuality: quality,
    );

    // A null pick is AMBIGUOUS on Android: it is a cancel, OR it is the
    // activity having been torn down and rebuilt while the gallery was in front
    // (low memory, or "Don't keep activities"), in which case the plugin parks
    // the result instead of returning it. Ask for the parked one before
    // concluding "cancelled" — otherwise a real selection silently evaporates,
    // which looks exactly like nothing happening.
    picked ??= await _picker.retrieveLost();
    if (picked == null) {
      DevUploadLog.instance.add('avatar: pick returned null (cancel or lost)');
      return null;
    }

    return _pickedFrom(picked);
  }

  /// Reclaims a parked selection WITHOUT opening the gallery.
  ///
  /// When Android destroys the host activity while the picker is in front, the
  /// Dart future awaiting [pickAvatar] dies with the old isolate — it never
  /// returns at all, so the fallback inside [pickAvatar] is never reached. The
  /// only way back to that photo is to ask for it again once the screen is
  /// rebuilt, which is why the Profile screen calls this on mount.
  @override
  Future<PickedAvatar?> recoverLostAvatar() async {
    final lost = await _picker.retrieveLost();
    if (lost == null) return null;
    DevUploadLog.instance.add('avatar: reclaimed a lost Android selection');
    return _pickedFrom(lost);
  }

  /// Reads [file] through the platform-neutral [XFile] API and wraps it, or
  /// throws [AvatarUploadFailure.unsupportedType] when the bytes are neither
  /// JPEG nor PNG.
  static Future<PickedAvatar> _pickedFrom(XFile file) async {
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (error, stack) {
      DevUploadLog.instance
          .add('avatar: could not read the picked file', error: error, stack: stack);
      throw AvatarUploadException(AvatarUploadFailure.unknown, error);
    }

    final contentType = _sniffContentType(bytes);
    if (contentType == null) {
      throw const AvatarUploadException(AvatarUploadFailure.unsupportedType);
    }
    DevUploadLog.instance
        .add('avatar: picked ${bytes.length} bytes as $contentType');
    return PickedAvatar(bytes: bytes, contentType: contentType);
  }

  /// The content type according to the file's MAGIC BYTES, or null when it is
  /// neither JPEG nor PNG.
  ///
  /// Sniffed rather than read off the extension on purpose: image_picker can
  /// hand back a `.png` path holding re-encoded JPEG bytes (it re-encodes when
  /// resizing). The content type is baked into the presigned PUT signature, so
  /// a mismatch surfaces as a confusing S3 403 at upload time rather than
  /// anything readable.
  /// Pure and synchronous — the server runs the identical check on the bytes it
  /// receives, and the two must not be able to disagree.
  static String? _sniffContentType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]; // \x89PNG\r\n\x1a\n
    if (bytes.length >= 8) {
      var matches = true;
      for (var i = 0; i < png.length; i++) {
        if (bytes[i] != png[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return 'image/png';
    }
    return null;
  }
}

/// App-wide gallery picker. Overridden in widget tests so the Profile screen's
/// avatar flow runs without a platform channel.
final avatarImagePickerProvider = Provider<AvatarImagePicker>(
  (ref) => const ImagePickerAvatarSource(),
);

/// The one call this feature makes into `image_picker`, isolated so tests can
/// substitute it without the plugin's platform channel.
abstract interface class AvatarPickerBackend {
  Future<XFile?> pick({
    required int maxWidth,
    required int maxHeight,
    required int imageQuality,
  });

  /// The selection Android parked when it tore our activity down, or null.
  Future<XFile?> retrieveLost();
}

class _DefaultPicker implements AvatarPickerBackend {
  const _DefaultPicker();

  @override
  Future<XFile?> pick({
    required int maxWidth,
    required int maxHeight,
    required int imageQuality,
  }) {
    return ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: maxWidth.toDouble(),
      maxHeight: maxHeight.toDouble(),
      imageQuality: imageQuality,
    );
  }

  /// NEVER throws. This is a best-effort PROBE that runs on every mount of the
  /// Profile screen, so any failure of its own is the app's problem, not the
  /// user's — a probe that could throw would paint an error over a screen the
  /// user merely opened, which is a worse bug than the one it exists to fix.
  @override
  Future<XFile?> retrieveLost() async {
    // ANDROID ONLY, and not by preference: `getLostData` is implemented solely
    // by image_picker_android. The platform interface's default THROWS
    // UnimplementedError, so calling this on iOS/web/desktop would turn a
    // successful pick into a crash.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

    try {
      final response = await ImagePicker().retrieveLostData();
      if (response.isEmpty) return null;

      // A failure the plugin recorded while we were not alive to hear it. There
      // is no photo to recover either way, so it is logged, not raised.
      final exception = response.exception;
      if (exception != null) {
        DevUploadLog.instance
            .add('avatar: lost-data probe reported a failure', error: exception);
        return null;
      }
      return response.file;
    } catch (error, stack) {
      DevUploadLog.instance
          .add('avatar: lost-data probe threw', error: error, stack: stack);
      return null;
    }
  }
}
