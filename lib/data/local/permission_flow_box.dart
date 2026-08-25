// lib/data/local/permission_flow_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/permission_flow_state.dart';
import '../../domain/entities/permission_item.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// The flow-state store contract the UI depends on. Lets the gate read/persist
/// flow facts without binding to Hive (tests inject a fake). Grant status is NOT
/// part of this contract — it is always read live via the permission facade.
abstract interface class PermissionFlowStore {
  /// Flow state for [type]; [PermissionFlowState.initial] when absent/corrupt.
  Future<PermissionFlowState> get(AppPermissionType type);

  /// Records that the OS prompt has been triggered for [type] at least once.
  Future<void> markAsked(AppPermissionType type);

  /// Records that the user chose to proceed without [type]
  /// (recommended/optional permissions only).
  Future<void> markSkipped(AppPermissionType type);
}

/// Hive-backed [PermissionFlowStore]. Stores one JSON record per permission in
/// the `permission_flow` `Box<String>` (same JSON-string convention as the
/// other boxes — no TypeAdapters).
///
/// Resilience: every operation is wrapped so it NEVER throws past this class.
/// A missing/corrupt record — or an environment where Hive is unavailable —
/// degrades [get] to [PermissionFlowState.initial] (safe first-run) and makes
/// writes no-op. It never defaults to "granted/asked".
class PermissionFlowBox implements PermissionFlowStore {
  PermissionFlowBox();

  Box<String>? _box;

  /// Opens the box, returning null on ANY failure (corrupt box, or Hive not
  /// initialized — e.g. a widget-test host). Callers degrade to safe defaults.
  /// Deliberately does NOT cache an in-flight future: caching a rejected open
  /// would resurface its error on every later await.
  Future<Box<String>?> _tryOpen() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    try {
      return _box = await openStringBoxSafely(BoxNames.permissionFlow);
    } catch (_) {
      return null;
    }
  }

  /// Stable per-permission storage key (decoupled from analytics tokens).
  String _keyFor(AppPermissionType type) => switch (type) {
        AppPermissionType.camera => 'camera',
        AppPermissionType.motion => 'motion',
        AppPermissionType.photos => 'photos',
      };

  @override
  Future<PermissionFlowState> get(AppPermissionType type) async {
    try {
      final box = await _tryOpen();
      if (box == null) return PermissionFlowState.initial;
      final raw = box.get(_keyFor(type));
      if (raw == null || raw.isEmpty) return PermissionFlowState.initial;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return PermissionFlowState.initial;
      return PermissionFlowState.fromJson(decoded);
    } catch (_) {
      // Corrupt JSON, schema issue, or Hive unavailable → safe first-run.
      return PermissionFlowState.initial;
    }
  }

  @override
  Future<void> markAsked(AppPermissionType type) =>
      _update(type, (s) => s.copyWith(hasBeenAsked: true));

  @override
  Future<void> markSkipped(AppPermissionType type) =>
      _update(type, (s) => s.copyWith(userSkipped: true));

  /// Read-modify-write a single permission's flow state. No-ops on any failure.
  Future<void> _update(
    AppPermissionType type,
    PermissionFlowState Function(PermissionFlowState) change,
  ) async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      final current = await get(type);
      final next = change(current);
      await box.put(_keyFor(type), jsonEncode(next.toJson()));
    } catch (_) {
      // Persistence unavailable — fail silent (flow falls back to defaults).
    }
  }

  /// Clears all stored flow state (e.g. on logout / account switch).
  Future<void> clear() async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      for (final type in AppPermissionType.values) {
        await box.delete(_keyFor(type));
      }
    } catch (_) {
      // No-op on failure.
    }
  }
}
