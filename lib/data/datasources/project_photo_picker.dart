// lib/data/datasources/project_photo_picker.dart
//
// Picks an artist's PHOTO SET (3..48 images) from the device gallery for an
// upload project.
//
// ── WHAT IT DELIBERATELY DOES NOT DO ────────────────────────────────────────
// It does not read 48 files into memory on native. `image_picker` returns an
// XFile per photo; on native that wraps a real path and the upload engine
// streams the bytes off disk part-by-part (FilePartByteSource). Only WEB has no
// path, and only there are the bytes held. Sniffing the content type does read
// a short HEAD of each file — never the whole thing.
//
// ── PERMISSIONS ─────────────────────────────────────────────────────────────
// Same stance as avatar_image_picker: NOT routed through the app's native
// permission channel. Android 13+ reaches the system photo picker with no
// runtime permission, and iOS's limited-library picker likewise returns files
// without a prompt in the common case (NSPhotoLibraryUsageDescription in
// ios/Runner/Info.plist covers the case where it does ask). A READ_MEDIA_IMAGES
// gate here would ask for a permission the picker does not need.
//
// Every bound checked here is ALSO enforced by the server. The client check
// exists so the artist finds out at pick time rather than after a minute of
// uploading.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../dev/dev_log/dev_upload_log.dart';
import '../../utils/image_content_type.dart';

/// Fewest photos an upload project may hold. Mirrors the backend's
/// `PROJECT_PHOTO_MIN_COUNT` (default 3) — hand-synced, like every other shared
/// constant in this repo.
const int kProjectPhotoMinCount = 3;

/// Most photos an upload project may hold — the backend's
/// `PROJECT_PHOTO_MAX_COUNT` (default 48). Matches CaptureMode.full's shot
/// count, so an uploaded set and a guided capture are comparably sized.
const int kProjectPhotoMaxCount = 48;

/// Hard per-photo ceiling in bytes — the backend's `PROJECT_PHOTO_MAX_BYTES`
/// (default 15 MiB), enforced there at COMMIT time because presigning cannot
/// cap a body.
const int kProjectPhotoMaxBytes = 15 * 1024 * 1024;

/// One photo the artist chose and the app accepted.
///
/// Carries EITHER a [path] (native — the engine streams it off disk) or [bytes]
/// (web — there is no filesystem path behind a `blob:` URL). Never both, and
/// never neither.
@immutable
class PickedProjectPhoto {
  const PickedProjectPhoto({
    required this.name,
    required this.size,
    required this.contentType,
    this.path,
    this.bytes,
  }) : assert(
          (path == null) != (bytes == null),
          'a picked photo carries exactly one of path or bytes',
        );

  /// The file's display name, for the upload-progress list. DISPLAY only — it
  /// never reaches a key (the server assigns those), never a log, and never the
  /// wire. Same treatment as [RejectedProjectPhoto.name].
  final String name;

  /// Device-absolute path — NATIVE only. Null on web.
  final String? path;

  /// The photo's bytes — WEB only. Null on native, deliberately: holding 48
  /// full-resolution photos in memory is how this feature would OOM a phone.
  final Uint8List? bytes;

  /// Size in bytes. Drives chunking and the total-bytes progress contract.
  final int size;

  /// `image/jpeg`, `image/png` or `image/webp` — SNIFFED from the file's own
  /// bytes, never inferred from its name or the OS-reported MIME.
  final String contentType;
}

/// Why one specific file was dropped. Surfaced PER FILE — a photo is never
/// silently discarded.
enum PhotoRejectionReason {
  /// Not a JPEG, PNG or WebP (by magic bytes).
  unsupportedType,

  /// Larger than [kProjectPhotoMaxBytes].
  tooLarge,

  /// The file could not be read at all.
  unreadable,

  /// Accepted files already filled [kProjectPhotoMaxCount].
  overCount,
}

@immutable
class RejectedProjectPhoto {
  const RejectedProjectPhoto({required this.name, required this.reason});

  /// The file's display name, for the "we skipped these" message. Used for
  /// DISPLAY only — it never reaches a key (the server assigns those).
  final String name;
  final PhotoRejectionReason reason;
}

/// The outcome of one pick. Both lists may be non-empty at once: some photos
/// accepted, some skipped with a reason.
@immutable
class PickedPhotoSet {
  const PickedPhotoSet({required this.accepted, required this.rejected});

  static const empty = PickedPhotoSet(accepted: [], rejected: []);

  final List<PickedProjectPhoto> accepted;
  final List<RejectedProjectPhoto> rejected;

  bool get isEmpty => accepted.isEmpty && rejected.isEmpty;
}

/// Gallery picker seam. An interface so the screens' tests drive a pick without
/// a platform channel.
abstract interface class ProjectPhotoPicker {
  /// Opens the system gallery picker for multiple images.
  ///
  /// [alreadyPicked] is how many photos the artist has already accepted in this
  /// session, so the count cap applies across repeated picks rather than per
  /// pick. Returns [PickedPhotoSet.empty] when the user cancels — a silent
  /// no-op, not an error.
  Future<PickedPhotoSet> pickPhotos({int alreadyPicked = 0});
}

class ImagePickerProjectPhotoSource implements ProjectPhotoPicker {
  const ImagePickerProjectPhotoSource([this._backend = const _DefaultMultiPicker()]);

  final ProjectPhotoPickerBackend _backend;

  @override
  Future<PickedPhotoSet> pickPhotos({int alreadyPicked = 0}) async {
    final picked = await _backend.pickMulti();
    if (picked.isEmpty) return PickedPhotoSet.empty;

    final accepted = <PickedProjectPhoto>[];
    final rejected = <RejectedProjectPhoto>[];
    var remaining = kProjectPhotoMaxCount - alreadyPicked;

    for (final file in picked) {
      final name = file.name;
      if (remaining <= 0) {
        rejected.add(RejectedProjectPhoto(name: name, reason: PhotoRejectionReason.overCount));
        continue;
      }

      final photo = await _accept(file);
      switch (photo) {
        case _Accepted(:final value):
          accepted.add(value);
          remaining--;
        case _Rejected(:final reason):
          rejected.add(RejectedProjectPhoto(name: name, reason: reason));
      }
    }

    DevUploadLog.instance.add(
      'photo set: ${accepted.length} accepted, ${rejected.length} skipped',
    );
    return PickedPhotoSet(accepted: accepted, rejected: rejected);
  }

  /// Validates ONE file: size first (cheap, and a huge file is dropped before
  /// anything is read), then the content type from its magic bytes.
  Future<_PhotoResult> _accept(XFile file) async {
    final int size;
    try {
      size = await file.length();
    } catch (error, stack) {
      DevUploadLog.instance.add('photo set: could not stat a picked file',
          error: error, stack: stack);
      return const _Rejected(PhotoRejectionReason.unreadable);
    }
    if (size <= 0) return const _Rejected(PhotoRejectionReason.unreadable);
    if (size > kProjectPhotoMaxBytes) {
      return const _Rejected(PhotoRejectionReason.tooLarge);
    }

    // On web there is no path to stream from later, so the bytes read here ARE
    // the upload payload and are kept. On native NOTHING is kept, and nothing
    // whole is even read: only the [kImageSniffHeaderBytes] the sniffer needs
    // come off disk, and the engine re-reads each part's range later. Reading
    // every photo in full here — which is what this did — pulled the WHOLE set
    // through RAM at pick time, 48 x up to 15 MiB of short-lived allocations on
    // the UI isolate, for the sake of 12 magic bytes.
    final Uint8List head;
    Uint8List? payload;
    try {
      if (kIsWeb) {
        payload = await file.readAsBytes();
        head = payload;
      } else {
        head = await _readHead(file, kImageSniffHeaderBytes);
      }
    } catch (error, stack) {
      DevUploadLog.instance.add('photo set: could not read a picked file',
          error: error, stack: stack);
      return const _Rejected(PhotoRejectionReason.unreadable);
    }

    final contentType = sniffImageContentType(head, allowWebp: true);
    if (contentType == null) {
      return const _Rejected(PhotoRejectionReason.unsupportedType);
    }

    return _Accepted(PickedProjectPhoto(
      name: file.name,
      size: size,
      contentType: contentType,
      path: kIsWeb ? null : file.path,
      // Native keeps nothing; only the web branch above produced a payload.
      bytes: payload,
    ));
  }
}

/// Reads at most [maxBytes] leading bytes of [file].
///
/// `openRead(0, maxBytes)` STREAMS, so a 15 MiB photo yields one short chunk and
/// the rest of the file is never touched; leaving the loop cancels the
/// subscription and closes the handle. Chunks may arrive shorter than asked for,
/// so they accumulate until the sniffer has enough or the file ends.
Future<Uint8List> _readHead(XFile file, int maxBytes) async {
  final head = <int>[];
  await for (final chunk in file.openRead(0, maxBytes)) {
    head.addAll(chunk);
    if (head.length >= maxBytes) break;
  }
  return Uint8List.fromList(head);
}

sealed class _PhotoResult {
  const _PhotoResult();
}

class _Accepted extends _PhotoResult {
  const _Accepted(this.value);
  final PickedProjectPhoto value;
}

class _Rejected extends _PhotoResult {
  const _Rejected(this.reason);
  final PhotoRejectionReason reason;
}

/// The one call this feature makes into `image_picker`, isolated so tests can
/// substitute it without the plugin's platform channel.
abstract interface class ProjectPhotoPickerBackend {
  Future<List<XFile>> pickMulti();
}

class _DefaultMultiPicker implements ProjectPhotoPickerBackend {
  const _DefaultMultiPicker();

  @override
  Future<List<XFile>> pickMulti() =>
      // No maxWidth/maxHeight/imageQuality: re-encoding here would degrade the
      // exact photographs the artist chose, and photogrammetry input is the one
      // place resolution is the product.
      ImagePicker().pickMultiImage(limit: kProjectPhotoMaxCount);
}

/// App-wide project-photo picker. Overridden in widget tests.
final projectPhotoPickerProvider = Provider<ProjectPhotoPicker>(
  (ref) => const ImagePickerProjectPhotoSource(),
);
