// lib/application/projects/image_prep_exporter.dart
//
// The Prepare-Images EXPORT pass: bakes one image's ImageEditState into a new
// JPEG (rotate → crop → downscale → lighting → white fill), producing the
// edited COPY that is uploaded for Meshy generation. The original bytes are
// never modified.
//
// Fidelity contract: the math here consumes the SAME LightingAdjust linear map
// and the SAME polygon/crop helpers the live preview renders with
// (domain/entities/image_edit.dart), so the exported file matches what the
// user saw. Order of operations (rotate first, white fill LAST so the
// background stays pure white regardless of lighting) mirrors the preview's
// paint order: overlays sit on top of the color-filtered image.
//
// Pure-Dart `image` package on purpose (no native plugin); the decode+encode
// of a 12MP capture takes seconds, so production wraps it in `compute` to stay
// off the UI thread. Output is JPEG quality 90, never alpha, long side capped
// at kMaxExportLongSidePx. A crop below kMinExportLongSidePx is flagged tight
// — NEVER upscaled.
//
// ORIENTATION, and why there is no bakeOrientation call: our captures carry
// EXIF orientation as a TAG (CameraX never rotates the sensor buffer), and
// img.decodeImage APPLIES that tag on decode, clearing it. So the buffer this
// function works on is already display-oriented — the same space the screen's
// Image.memory shows and the user drew their crop in. That is load-bearing and
// pinned by test; anything that swaps this decoder must preserve it. (The
// screen must obtain its dimensions the same way, which is why the LOADER
// measures via dart:ui rather than a header-only read — a raw SOF read reports
// these un-rotated and skews every normalized coordinate.)
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../domain/entities/image_edit.dart';

/// JPEG quality for exported model-input copies (~90 per the feature spec —
/// visually lossless for photogrammetry-style inputs, reasonable upload size).
const int kExportJpegQuality = 90;

/// One exported edited copy.
class ExportedImage {
  const ExportedImage({
    required this.jpegBytes,
    required this.width,
    required this.height,
    required this.isTight,
  });

  final Uint8List jpegBytes;
  final int width;
  final int height;

  /// True when the result is under the [kMinExportLongSidePx] guard — the
  /// caller shows the "Very tight crop" warning but still allows proceeding.
  final bool isTight;
}

/// Seam over "bake an edit into a JPEG": production computes in an isolate;
/// widget tests inject a fake so pumping the screen never decodes real images.
abstract interface class ImagePrepExporter {
  Future<ExportedImage> export(Uint8List originalBytes, ImageEditState edit);
}

/// Production [ImagePrepExporter]: runs [exportEditedImage] via [compute]
/// (a no-op wrapper on web, where isolates aren't available — the export
/// still completes, just on the main thread).
class ComputeImagePrepExporter implements ImagePrepExporter {
  const ComputeImagePrepExporter();

  @override
  Future<ExportedImage> export(Uint8List originalBytes, ImageEditState edit) =>
      compute(_exportEntry, (originalBytes, edit));
}

ExportedImage _exportEntry((Uint8List, ImageEditState) args) =>
    exportEditedImage(args.$1, args.$2);

/// Synchronous export pipeline — top-level and pure so unit tests call it
/// directly on tiny synthetic images.
///
/// Throws [FormatException] when [originalBytes] does not decode.
ExportedImage exportEditedImage(Uint8List originalBytes, ImageEditState edit) {
  // decodeImage returns null for unknown formats but can also THROW on
  // corrupt bytes (its format probes read headers unguarded) — normalize both
  // into the one FormatException the caller maps to user copy.
  img.Image? decoded;
  try {
    decoded = img.decodeImage(originalBytes);
  } catch (_) {
    decoded = null;
  }
  var image = decoded;
  if (image == null) {
    throw const FormatException('Could not decode the selected image.');
  }

  // 1. Rotation — FIRST, because every normalized edit coordinate is defined
  // in rotated-image space (the space the user edited in).
  if (edit.quarterTurns != 0) {
    image = img.copyRotate(image, angle: 90.0 * edit.quarterTurns);
  }

  // Meshy input must have no alpha: flatten any transparent source onto white
  // before anything samples pixels. (Captures are JPEG already; this guards
  // gallery entries that arrive as PNG.)
  if (image.hasAlpha) {
    final flat = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 3,
    );
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, image);
    image = flat;
  }

  final fullWidth = image.width;
  final fullHeight = image.height;

  // 2. Crop to the working window: the polygon's padded bounding box, or the
  // rectangle. Done BEFORE lighting so the per-pixel pass only touches kept
  // pixels.
  final polygon = edit.polygon;
  PixelRect? window;
  if (polygon != null && polygon.length >= 3) {
    window = paddedPolygonCropRect(polygon, fullWidth, fullHeight);
  } else if (edit.rect != null && !edit.rect!.isFullImage) {
    window = rectCropToPixels(edit.rect!, fullWidth, fullHeight);
  }
  if (window != null) {
    image = img.copyCrop(
      image,
      x: window.x,
      y: window.y,
      width: window.width,
      height: window.height,
    );
  }

  // 3. Downscale to the upload budget. Done BEFORE lighting (the per-pixel
  // pass then runs over far fewer pixels on a 12MP source) and BEFORE the
  // white fill (so the polygon edge is drawn crisply at final resolution
  // instead of being resampled into a grey fringe).
  //
  // NOTE the deliberate asymmetry: an UNTOUCHED photo never reaches this
  // function at all — it keeps its original key and is not re-uploaded — so
  // the cap applies only to edited images. Re-uploading untouched photos just
  // to shrink them would cost S3 writes and break the "no edit → no upload"
  // contract the screen tests pin.
  final target = downscaleTarget(image.width, image.height);
  if (target != null) {
    image = img.copyResize(
      image,
      width: target.width,
      height: target.height,
      interpolation: img.Interpolation.average,
    );
  }

  // 4. Lighting — the same linear map the preview's ColorFilter.matrix runs.
  if (!edit.lighting.isNeutral) {
    final scales = edit.lighting.channelScales;
    final offset = edit.lighting.channelOffset;
    for (final pixel in image) {
      pixel.r = LightingAdjust.applyToChannel(pixel.r, scales[0], offset);
      pixel.g = LightingAdjust.applyToChannel(pixel.g, scales[1], offset);
      pixel.b = LightingAdjust.applyToChannel(pixel.b, scales[2], offset);
    }
  }

  // 5. White fill outside the polygon — LAST, so the background is solid
  // 255/255/255 no matter what lighting did. Scanline spans per row keep this
  // O(rows × vertices) instead of point-in-polygon per pixel.
  if (polygon != null && polygon.length >= 3 && window != null) {
    _whitenOutsidePolygon(image, polygon, window, fullWidth, fullHeight);
  }

  return ExportedImage(
    jpegBytes: img.encodeJpg(image, quality: kExportJpegQuality),
    width: image.width,
    height: image.height,
    isTight: isTightCrop(image.width, image.height),
  );
}

/// Fills every pixel of [cropped] that lies OUTSIDE [polygon] with solid
/// white. [polygon] is normalized to the FULL rotated image; [window] locates
/// the crop within it.
///
/// [cropped] may have been DOWNSCALED since the crop, so its dimensions are
/// not assumed equal to [window]'s — the two scale factors below convert
/// cropped-pixel ↔ full-image-pixel. When no resize happened both are exactly
/// 1.0 and the arithmetic reduces to the plain window offset.
void _whitenOutsidePolygon(
  img.Image cropped,
  List<EditPoint> polygon,
  PixelRect window,
  int fullWidth,
  int fullHeight,
) {
  final white = img.ColorRgb8(255, 255, 255);
  final scaleX = window.width / cropped.width;
  final scaleY = window.height / cropped.height;

  for (var y = 0; y < cropped.height; y++) {
    // Sample the row at the pixel-center in full-image normalized space.
    final yNorm = (window.y + (y + 0.5) * scaleY) / fullHeight;
    final spans = polygonRowSpans(yNorm, polygon);

    var x = 0;
    // Walk (outside, inside) alternating span pairs left → right.
    for (var i = 0; i < spans.length; i += 2) {
      final insideStart = ((spans[i] * fullWidth - window.x) / scaleX)
          .floor()
          .clamp(0, cropped.width);
      final insideEnd = (i + 1 < spans.length)
          ? ((spans[i + 1] * fullWidth - window.x) / scaleX)
              .ceil()
              .clamp(0, cropped.width)
          : cropped.width;
      for (; x < insideStart; x++) {
        cropped.setPixel(x, y, white);
      }
      x = insideEnd > x ? insideEnd : x;
    }
    for (; x < cropped.width; x++) {
      cropped.setPixel(x, y, white);
    }
  }
}

/// App-wide exporter seam (staff Prepare-Images surface).
final imagePrepExporterProvider = Provider<ImagePrepExporter>(
  (ref) => const ComputeImagePrepExporter(),
);
