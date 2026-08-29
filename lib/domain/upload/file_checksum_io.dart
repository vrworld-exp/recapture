// lib/domain/upload/file_checksum_io.dart
//
// NATIVE half of the streaming checksum source: `File.openRead()`, exactly what
// StreamingMd5Checksum did before the platform split. Bounded memory regardless
// of file size; a missing file's error propagates rather than becoming a blank
// digest.
import 'dart:io';

Stream<List<int>> openChecksumStream(String path) => File(path).openRead();
