// lib/data/local/hive_init.dart
import 'package:hive_flutter/hive_flutter.dart';

import 'box_names.dart';

/// Initializes Hive exactly once, before `runApp`. Values are stored as JSON
/// strings (no generated TypeAdapters), so there is nothing to register here.
Future<void> initHive() async {
  await Hive.initFlutter();
}

/// Opens a `Box<String>` with corruption + schema-version recovery. Any failure
/// degrades the box to "empty" — it never throws past here, so a bad box on disk
/// can never crash app startup.
///
/// Behaviour:
///   - Already open → reuse the open instance (no double-open).
///   - Corrupt box (open throws [HiveError]) → wipe from disk, reopen empty.
///   - Stored schema version ≠ [BoxSchema.version] → clear (clear-on-mismatch).
Future<Box<String>> openStringBoxSafely(String name) async {
  if (Hive.isBoxOpen(name)) {
    return _reconcileVersion(Hive.box<String>(name));
  }
  try {
    return await _reconcileVersion(await Hive.openBox<String>(name));
  } on HiveError {
    await Hive.deleteBoxFromDisk(name);
    return _reconcileVersion(await Hive.openBox<String>(name));
  }
}

Future<Box<String>> _reconcileVersion(Box<String> box) async {
  final stored = box.get(BoxSchema.versionKey);
  if (stored != null && int.tryParse(stored) != BoxSchema.version) {
    await box.clear(); // incompatible schema, no migration defined → reset
  }
  await box.put(BoxSchema.versionKey, BoxSchema.version.toString());
  return box;
}
