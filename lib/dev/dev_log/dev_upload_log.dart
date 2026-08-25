// lib/dev/dev_log/dev_upload_log.dart
//
// DEV-ONLY in-memory timeline of the upload flow, surfaced as a panel on
// Screen 9F so on-device testing can see exactly which step failed (and the
// raw error behind a mapped code like UNK-01) without adb. Compile-time gated
// on the same flavor switch as the Dev Tools section / OTP dev chip:
// [add] is a no-op under `--dart-define=ENV=prod`, so production builds never
// accumulate (or render) any of this.
//
// The buffer is process-memory only — never persisted, never sent to
// analytics. Raw error strings (which may contain URLs/status bodies) are
// acceptable HERE precisely because this surface cannot exist in a production
// build; the user-facing 9F copy stays mapped-category-only.
import 'package:flutter/foundation.dart';

import '../../utils/app_env.dart';

/// One timestamped line in the dev upload log.
class DevLogEntry {
  DevLogEntry(this.at, this.message);

  final DateTime at;
  final String message;

  String get line => '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}'
      '.${at.millisecond.toString().padLeft(3, '0')}  $message';

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// App-global ring buffer of upload-flow diagnostics. A singleton (not a
/// provider) so deep pipeline classes can log without threading a dependency
/// through every seam — acceptable for a dev-flavor-only tool.
class DevUploadLog extends ChangeNotifier {
  DevUploadLog._();

  static final DevUploadLog instance = DevUploadLog._();

  static const int _cap = 300;

  final List<DevLogEntry> _entries = [];

  /// Snapshot of the entries, oldest first.
  List<DevLogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  /// Appends one line (plus the error's type/text and the head of its stack
  /// when provided). No-op in prod-flavor builds.
  void add(String message, {Object? error, StackTrace? stack}) {
    if (kAppEnvironment.isProduction) return;
    var m = message;
    if (error != null) {
      m = '$m — ${error.runtimeType}: $error';
    }
    if (stack != null) {
      final head = stack.toString().split('\n').take(3).join('\n    ');
      m = '$m\n    $head';
    }
    _entries.add(DevLogEntry(DateTime.now(), m));
    if (_entries.length > _cap) {
      _entries.removeRange(0, _entries.length - _cap);
    }
    debugPrint('[upload-dev] $m');
    notifyListeners();
  }

  /// The whole buffer as copyable text.
  String dumpText() => _entries.map((e) => e.line).join('\n');

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
