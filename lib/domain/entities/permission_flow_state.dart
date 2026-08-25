// lib/domain/entities/permission_flow_state.dart
import 'package:flutter/foundation.dart';

/// App-side FLOW state for a single permission — persisted so the app does not
/// re-prompt or nag unnecessarily across resume/relaunch.
///
/// CRITICAL: this records only UX-flow facts. It deliberately holds NO `granted`
/// field. The OS is the sole authority on grant status (the user can change it
/// in Settings at any time), so grant status is ALWAYS read live via the
/// permission facade — never cached here. Caching "granted" would risk acting on
/// a permission the user has since revoked.
@immutable
class PermissionFlowState {
  const PermissionFlowState({
    this.hasBeenAsked = false,
    this.userSkipped = false,
  });

  /// The app has triggered the OS prompt for this permission at least once.
  /// Used to avoid surprising re-prompts and to distinguish first-run from
  /// returning flow — NOT to infer whether it is granted.
  final bool hasBeenAsked;

  /// The user explicitly chose to proceed without this recommended/optional
  /// permission. Used to stop nagging on every resume; the permission can still
  /// be enabled manually and a live grant always takes effect.
  final bool userSkipped;

  /// Safe baseline used for fresh installs and for missing/corrupt stored data:
  /// behave as first-run (not asked, not skipped). Never assumes granted/asked.
  static const PermissionFlowState initial = PermissionFlowState();

  PermissionFlowState copyWith({bool? hasBeenAsked, bool? userSkipped}) =>
      PermissionFlowState(
        hasBeenAsked: hasBeenAsked ?? this.hasBeenAsked,
        userSkipped: userSkipped ?? this.userSkipped,
      );

  Map<String, dynamic> toJson() => {
        'hasBeenAsked': hasBeenAsked,
        'userSkipped': userSkipped,
      };

  /// Tolerant of missing/extra fields — any absent flag defaults to the safe
  /// `false`, so a partially-written record degrades to first-run, not granted.
  factory PermissionFlowState.fromJson(Map<String, dynamic> json) =>
      PermissionFlowState(
        hasBeenAsked: json['hasBeenAsked'] as bool? ?? false,
        userSkipped: json['userSkipped'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is PermissionFlowState &&
      other.hasBeenAsked == hasBeenAsked &&
      other.userSkipped == userSkipped;

  @override
  int get hashCode => Object.hash(hasBeenAsked, userSkipped);

  @override
  String toString() =>
      'PermissionFlowState(hasBeenAsked: $hasBeenAsked, userSkipped: $userSkipped)';
}
