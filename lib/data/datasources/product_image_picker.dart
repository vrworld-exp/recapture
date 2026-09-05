// lib/data/datasources/product_image_picker.dart
//
// Picks ONE catalog-product photo from the device gallery and decides its
// content type from the file's own bytes.
//
// SEPARATE from avatar_image_picker.dart on purpose, and not a parameter on it:
// the two differ in the three things that matter. A product image is public
// catalog content rendered as a card and opened full-bleed, so it keeps a much
// larger long edge than a 96px avatar ring needs; it accepts WebP, which the
// avatar key space does not; and it is bounded by the catalog's own 5 MiB
// ceiling rather than the avatar's 2 MiB. Widening the avatar picker to cover
// all three would leave one picker whose limits belong to neither feature.
//
// PERMISSIONS: deliberately NOT routed through the app's native permission
// channel, for the reason given at length in avatar_image_picker.dart — the
// system photo picker needs no runtime permission on Android 13+, and adding a
// READ_MEDIA_IMAGES gate would ask for one the picker does not use.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../dev/dev_log/dev_upload_log.dart';

/// One picked product image: the BYTES and the content type those bytes say
/// they are.
///
/// Bytes, not a `dart:io` File, because this runs on WEB too — there the picker
/// returns an [XFile] wrapping a `blob:` URL with no path on any filesystem, so
/// `File(xfile.path)` compiles and then throws the moment it is read.
class PickedProductImage {
  const PickedProductImage({required this.bytes, required this.contentType});

  final Uint8List bytes;

  /// `image/jpeg`, `image/png` or `image/webp` — sniffed, never inferred from
  /// the extension.
  final String contentType;

  int get length => bytes.length;
}

/// Why a pick could not be used. Both are the user's problem to fix, so both
/// carry a sentence rather than a code the screen would have to translate.
enum ProductImagePickFailure {
  /// Neither JPEG, PNG nor WebP.
  unsupportedType,

  /// Over [ProductImagePickerSource.maxBytes] — the server's own ceiling,
  /// checked here so the user finds out before the upload rather than after it.
  tooLarge,

  /// The file could not be read at all.
  unreadable,
}

extension ProductImagePickFailureX on ProductImagePickFailure {
  String get message => switch (this) {
        ProductImagePickFailure.unsupportedType =>
          'That file is not a JPEG, PNG or WebP.',
        ProductImagePickFailure.tooLarge =>
          'That image is too large. Please choose one under 5 MB.',
        ProductImagePickFailure.unreadable =>
          "That image couldn't be read. Please choose another.",
      };
}

class ProductImagePickException implements Exception {
  const ProductImagePickException(this.failure, [this.cause]);

  final ProductImagePickFailure failure;
  final Object? cause;

  String get message => failure.message;

  @override
  String toString() => 'ProductImagePickException(${failure.name})';
}

/// Gallery picker seam. An interface so the add-product screen's tests can drive
/// a pick without a platform channel.
abstract interface class ProductImagePicker {
  /// Opens the system gallery picker. Returns null when the user CANCELS — a
  /// silent no-op, not an error.
  ///
  /// Throws [ProductImagePickException] when the chosen file is unusable, so
  /// the user finds out before anything is uploaded.
  Future<PickedProductImage?> pickProductImage();
}

class ProductImagePickerSource implements ProductImagePicker {
  const ProductImagePickerSource([this._picker = const _DefaultPicker()]);

  final ProductImagePickerBackend _picker;

  /// The longest edge of a stored product image. A product card is a grid tile
  /// on a phone but the same image opens full-bleed in the public catalog, so
  /// this is generous where the avatar's 512 is not.
  ///
  /// NATIVE ONLY. `image_picker_for_web` has no native encoder and ignores
  /// maxWidth/maxHeight/imageQuality, so a web pick arrives at its ORIGINAL
  /// dimensions and weight — which is exactly why [maxBytes] below has to be a
  /// real, user-visible failure rather than a formality.
  static const int maxDimension = 2048;

  /// JPEG re-encode quality (native only, same caveat as [maxDimension]).
  static const int quality = 85;

  /// Hand-synced with `CATALOG_PRODUCT_IMAGE_MAX_BYTES` in
  /// `recapture-api/src/config/env.ts` (there is no shared package — AGENTS.md
  /// §0.1). Checked here only so the user is told before a 5 MiB upload is
  /// attempted; the server remains the authority and rejects it too.
  static const int maxBytes = 5 * 1024 * 1024;

  @override
  Future<PickedProductImage?> pickProductImage() async {
    final picked = await _picker.pick(
      maxWidth: maxDimension,
      maxHeight: maxDimension,
      imageQuality: quality,
    );
    if (picked == null) {
      DevUploadLog.instance.add('product image: pick returned null (cancel)');
      return null;
    }

    final Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (error, stack) {
      DevUploadLog.instance.add(
        'product image: could not read the picked file',
        error: error,
        stack: stack,
      );
      throw ProductImagePickException(
        ProductImagePickFailure.unreadable,
        error,
      );
    }

    final contentType = sniffContentType(bytes);
    if (contentType == null) {
      throw const ProductImagePickException(
        ProductImagePickFailure.unsupportedType,
      );
    }
    if (bytes.length > maxBytes) {
      throw const ProductImagePickException(ProductImagePickFailure.tooLarge);
    }

    DevUploadLog.instance
        .add('product image: picked ${bytes.length} bytes as $contentType');
    return PickedProductImage(bytes: bytes, contentType: contentType);
  }

  /// The content type according to the file's MAGIC BYTES, or null when it is
  /// none of the three we accept.
  ///
  /// Sniffed rather than read off the extension because image_picker re-encodes
  /// when it resizes and can hand back a `.png` path holding JPEG bytes. The
  /// server sniffs the identical way on the bytes it receives and derives the
  /// stored type from that, so the two must not be able to disagree.
  @visibleForTesting
  static String? sniffContentType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
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
    // RIFF....WEBP — the four size bytes at 4..7 are skipped on purpose.
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x45 && // E
        bytes[10] == 0x42 && // B
        bytes[11] == 0x50) {
      // P
      return 'image/webp';
    }
    return null;
  }
}

/// App-wide product-image picker. Overridden in widget tests so the add-product
/// screen runs without a platform channel.
final productImagePickerProvider = Provider<ProductImagePicker>(
  (ref) => const ProductImagePickerSource(),
);

/// The one call this feature makes into `image_picker`, isolated so tests can
/// substitute it without the plugin's platform channel.
abstract interface class ProductImagePickerBackend {
  Future<XFile?> pick({
    required int maxWidth,
    required int maxHeight,
    required int imageQuality,
  });
}

class _DefaultPicker implements ProductImagePickerBackend {
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
}
