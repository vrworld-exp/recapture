// lib/domain/upload/file_checksum_stub.dart
//
// Compile-time fallback for the platform-split checksum source. Only reachable
// on a target with neither `dart:io` nor `dart:js_interop`. It errors the stream
// rather than yielding nothing, so a pack fails loudly instead of shipping a
// manifest whose checksums silently describe zero bytes.
Stream<List<int>> openChecksumStream(String path) => Stream<List<int>>.error(
      UnsupportedError('Checksums are not supported on this platform: $path'),
    );
