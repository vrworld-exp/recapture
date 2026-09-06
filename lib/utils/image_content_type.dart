// lib/utils/image_content_type.dart
//
// The ONE image content-type sniffer. Extracted from
// data/datasources/avatar_image_picker.dart so the avatar picker and the
// project-photo picker cannot drift apart on what "a JPEG" means.
//
// ── WHY MAGIC BYTES AND NOT THE EXTENSION ───────────────────────────────────
// `image_picker` can hand back a `.png` path holding re-encoded JPEG bytes (it
// re-encodes when resizing), and the OS-reported MIME is no better. The content
// type is baked into the presigned PUT signature, so a mismatch surfaces as a
// confusing S3 403 at upload time rather than as anything readable.
//
// Pure and synchronous, with no Flutter or IO imports beyond `Uint8List`, so it
// is unit-testable and works identically on native and web. The SERVER runs its
// own check on the bytes it receives; the two must not be able to disagree.
import 'dart:typed_data';

/// The most leading bytes [sniffImageContentType] can ever need: the WebP check
/// reads through byte 11, so 12 is the exact floor and every other signature is
/// shorter. A caller streaming a file off disk reads THIS many and stops — see
/// `project_photo_picker.dart`, where reading whole photos just to sniff them
/// would pull a 48-photo set through RAM at pick time.
const int kImageSniffHeaderBytes = 12;

/// The content types this app will upload. Ordered as the sniffer tries them.
const String kContentTypeJpeg = 'image/jpeg';
const String kContentTypePng = 'image/png';
const String kContentTypeWebp = 'image/webp';

/// The content type [bytes] actually are, or null when they are none of the
/// types this app accepts.
///
/// [allowWebp] is false by default so the AVATAR path keeps its exact existing
/// behaviour (JPEG/PNG only — widening it silently would change what an avatar
/// upload accepts). The project-photo picker opts in.
String? sniffImageContentType(Uint8List bytes, {bool allowWebp = false}) {
  if (_startsWith(bytes, _jpegMagic)) return kContentTypeJpeg;
  if (_startsWith(bytes, _pngMagic)) return kContentTypePng;
  if (allowWebp && _isWebp(bytes)) return kContentTypeWebp;
  return null;
}

/// SOI + the first marker byte. Every JPEG variant (JFIF, Exif, raw) opens
/// with these three.
const List<int> _jpegMagic = [0xFF, 0xD8, 0xFF];

/// `\x89PNG\r\n\x1a\n` — the 8-byte PNG signature.
const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// WebP is a RIFF container: `RIFF????WEBP`, where `????` is the little-endian
/// file size. Both the literal chunks must match — checking only `RIFF` would
/// accept a WAV file.
const List<int> _riffMagic = [0x52, 0x49, 0x46, 0x46]; // 'RIFF'
const List<int> _webpMagic = [0x57, 0x45, 0x42, 0x50]; // 'WEBP'

bool _isWebp(Uint8List bytes) {
  if (bytes.length < 12) return false;
  if (!_startsWith(bytes, _riffMagic)) return false;
  for (var i = 0; i < _webpMagic.length; i++) {
    if (bytes[8 + i] != _webpMagic[i]) return false;
  }
  return true;
}

bool _startsWith(Uint8List bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}
