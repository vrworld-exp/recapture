// lib/data/datasources/model_file_picker.dart
//
// Picks ONE `.glb` off the device for the staff "Submit model" flow.
//
// ── WHY NOT image_picker ────────────────────────────────────────────────────
// Every other picker in this tree (avatar, product image, photo set) picks
// IMAGES, and image_picker is the right tool for those. A 3D model is an
// arbitrary binary file, which that plugin cannot offer at all — so this is the
// one place a general file browser is opened.
//
// ── A STREAM, NOT BYTES ─────────────────────────────────────────────────────
// A picked model carries a way to READ itself, not its contents. A submitted
// model is routinely tens of megabytes, and holding one in RAM to hand it to an
// upload is the exact allocation the photo-set flow documents avoiding. The
// picker's own `readAsByteStream()` is path-backed on native and blob-backed on
// web, so one shape covers both targets with no `kIsWeb` branch anywhere below
// this file.
//
// ── PERMISSIONS ─────────────────────────────────────────────────────────────
// None. Android reaches the Storage Access Framework (the system document
// picker), which grants per-file access with no runtime permission; the browser
// file input likewise. Nothing is added to the manifest for this.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The extension the picker offers and the only one the server accepts. The
/// server re-checks the file's own magic bytes — this is a convenience, not the
/// authority.
const String kModelFileExtension = 'glb';

/// One model file the staff user chose.
@immutable
class PickedModelFile {
  const PickedModelFile({
    required this.name,
    required this.size,
    required this.openRead,
  });

  /// A model already in memory — for tests, and for nothing else: production
  /// picks stream off the picker's own handle.
  factory PickedModelFile.fromBytes(String name, Uint8List bytes) =>
      PickedModelFile(
        name: name,
        size: bytes.length,
        openRead: () => Stream<List<int>>.value(bytes),
      );

  /// The file's display name, shown on the submit screen so the user can see
  /// WHICH file they are about to hand to someone else's project. DISPLAY only:
  /// it never reaches a key (the server assigns those) and never the wire.
  final String name;

  /// Size in bytes. Drives the client-side ceiling check and the upload's
  /// Content-Length, which a presigned PUT requires.
  final int size;

  /// Opens the file's bytes. Called ONCE per upload attempt — a retry calls it
  /// again for a fresh stream rather than replaying a consumed one.
  final Stream<List<int>> Function() openRead;
}

/// Picker seam. An interface so the submit screen's tests can drive a pick
/// without a platform channel.
abstract interface class ModelFilePicker {
  /// Opens the system file browser filtered to `.glb`. Returns null when the
  /// user CANCELS — a silent no-op, not an error.
  Future<PickedModelFile?> pickGlb();
}

class FilePickerModelFilePicker implements ModelFilePicker {
  const FilePickerModelFilePicker();

  @override
  Future<PickedModelFile?> pickGlb() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose a .glb model',
      type: FileType.custom,
      allowedExtensions: const [kModelFileExtension],
    );
    if (file == null) return null;

    // `length()` rather than `lengthSync()`: a picker that did not report a
    // size returns null from the sync form, and a zero size would sign the PUT
    // with a Content-Length the body then contradicts.
    final size = await file.length();
    return PickedModelFile(
      name: file.name,
      size: size,
      openRead: file.readAsByteStream,
    );
  }
}

final modelFilePickerProvider = Provider<ModelFilePicker>(
  (ref) => const FilePickerModelFilePicker(),
);
