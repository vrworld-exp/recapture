// lib/data/local/projects_cache_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/project.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// A read of the projects cache: the cached list plus when it was written.
class CachedProjects {
  const CachedProjects(this.projects, this.cachedAt);
  final List<Project> projects;
  final DateTime cachedAt;
}

/// Typed gateway over the (unencrypted) `projects_cache` box. Stores a single
/// JSON blob: `{ "cachedAt": <epochMs>, "projects": [ {...}, ... ] }`. Holds no
/// sensitive data. Hive types never leak past this class.
class ProjectsCacheBox {
  ProjectsCacheBox();

  static const String _key = 'data';

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    // Share a single in-flight open so concurrent calls never double-open.
    return _opening ??= openStringBoxSafely(BoxNames.projectsCache).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  /// Writes the list as a single JSON blob with a cache timestamp. Call only on
  /// a successful network fetch/refresh — never on every state mutation.
  Future<void> save(List<Project> projects) async {
    final payload = jsonEncode({
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
      'projects': [for (final p in projects) p.toMap()],
    });
    await (await _open()).put(_key, payload);
  }

  /// Returns the cached projects, or null when absent/corrupt. Parsing is
  /// defensive: unparseable rows are skipped and unknown fields ignored — it
  /// never throws, so a blob that predates a model change degrades to a partial
  /// or empty cache rather than crashing.
  Future<CachedProjects?> read() async {
    final raw = (await _open()).get(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final rawProjects = decoded['projects'];
      if (rawProjects is! List) return null;
      final projects = [
        for (final row in rawProjects)
          if (row is Map<String, dynamic>) Project.fromMap(row),
      ];
      final cachedAtMs = decoded['cachedAt'];
      final cachedAt = cachedAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(cachedAtMs)
          : DateTime.now();
      return CachedProjects(projects, cachedAt);
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() async {
    await (await _open()).delete(_key);
  }
}
