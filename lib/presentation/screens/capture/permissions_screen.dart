// lib/presentation/screens/capture/permissions_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/local/permission_flow_box.dart';
import '../../../domain/entities/permission_flow_state.dart';
import '../../../domain/entities/permission_item.dart';
import '../../../platform/permissions_service.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/permission_card.dart';

/// Permissions gate. Requests Camera (required), Motion (recommended), and
/// Photos (optional). The Continue CTA gates solely on Camera being granted —
/// Motion and Photos never block it.
///
/// Statuses are reflected on load (no auto-prompt) and re-checked on app
/// resume so returning from the OS settings screen updates the UI.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({
    super.key,
    this.service = const PermissionsService(),
    this.flowStore,
  });

  /// The permission gateway. Defaults to the real [PermissionsService] so the
  /// router builds it `const`; injectable so tests drive statuses without the
  /// OS (widgets never touch permission_handler directly).
  final PermissionsService service;

  /// Persisted permission-flow store (has-been-asked / user-skipped). Null →
  /// the real Hive-backed [PermissionFlowBox]; injectable for tests. Holds NO
  /// grant status — live OS status (via [service]) is always the authority.
  final PermissionFlowStore? flowStore;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  PermissionsService get _service => widget.service;

  late final PermissionFlowStore _flowStore = widget.flowStore ?? PermissionFlowBox();

  final Map<AppPermissionType, AppPermissionStatus> _statuses = {
    for (final item in defaultPermissionItems)
      item.type: AppPermissionStatus.notRequested,
  };

  /// Persisted FLOW state per permission (has-been-asked / user-skipped). Live
  /// OS status in [_statuses] is always the authority; this only suppresses
  /// re-nagging and reflects explicit skips.
  final Map<AppPermissionType, PermissionFlowState> _flow = {
    for (final item in defaultPermissionItems)
      item.type: PermissionFlowState.initial,
  };

  /// Per-permission in-flight guard — blocks duplicate OS prompts from a
  /// rapid double-tap on "Allow".
  final Set<AppPermissionType> _inFlight = <AppPermissionType>{};

  /// Debounce for the "Settings" deep link so rapid taps open it only once.
  bool _openingSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from OS settings: re-check everything so the UI reflects any
    // change the user made outside the app. Resume can reveal a transition the
    // app didn't drive (granted/revoked in Settings) — emit analytics for those.
    if (state == AppLifecycleState.resumed) {
      _refreshAll(emitTransitions: true);
    }
  }

  /// Re-checks LIVE OS status (non-prompting) for every permission and reloads
  /// persisted flow state. Runs on first build and on resume. It NEVER calls
  /// `request()` — the OS prompt is only triggered by explicit user action — so
  /// live status always wins over any stale flow assumption.
  ///
  /// [emitTransitions] is false on the initial load (it only establishes the
  /// baseline — emitting there would phantom-fire a grant for permissions a
  /// prior session already granted) and true on resume, where a change vs the
  /// in-session baseline is a real grant/deny transition worth tracking.
  Future<void> _refreshAll({bool emitTransitions = false}) async {
    final results = <AppPermissionType, AppPermissionStatus>{};
    final flows = <AppPermissionType, PermissionFlowState>{};
    for (final item in defaultPermissionItems) {
      results[item.type] = await _service.status(item.type);
      flows[item.type] = await _flowStore.get(item.type);
    }
    if (!mounted) return;
    if (emitTransitions) _emitResumeTransitions(results);
    setState(() {
      _statuses.addAll(results);
      _flow.addAll(flows);
    });
  }

  /// Compares the freshly-checked [next] statuses against the in-session
  /// baseline ([_statuses]) and emits analytics for grant/deny EDGE crossings
  /// only — never for passive same-status re-checks:
  ///   • not-granted → granted  ⇒ granted event (`source: settings_return`)
  ///   • granted → not-granted  ⇒ `permission_denied` (revocation in Settings)
  /// Transitions between two non-granted states are not grant/deny edges and
  /// emit nothing.
  void _emitResumeTransitions(Map<AppPermissionType, AppPermissionStatus> next) {
    for (final item in defaultPermissionItems) {
      final wasGranted = _statusOf(item.type).isGranted;
      final isGranted = (next[item.type] ?? AppPermissionStatus.notRequested).isGranted;
      if (wasGranted == isGranted) continue;
      if (isGranted) {
        _emitGranted(item.type, _GrantSource.settingsReturn);
      } else {
        _emitDenied(item, next[item.type]!);
      }
    }
  }

  Future<void> _onAllow(PermissionItem item) async {
    if (_inFlight.contains(item.type)) return; // double-tap guard
    setState(() => _inFlight.add(item.type));
    try {
      final result = await _service.request(item.type);
      // The OS prompt has now been shown at least once — persist the flow fact
      // (NOT the grant status, which stays live-only).
      await _flowStore.markAsked(item.type);
      // The request resolving IS the grant/deny transition (the Allow affordance
      // only shows when not granted, so this is always an edge). Emit once.
      if (result.isGranted) {
        _emitGranted(item.type, _GrantSource.prompt);
      } else {
        _emitDenied(item, result);
      }
      Analytics.logEvent('precapture_permission_result', {
        'permission_type': item.type.analyticsValue,
        'result': result.analyticsValue,
        'requirement': item.requirement.analyticsValue,
        'device_type': _deviceType,
      });
      if (!mounted) return;
      setState(() {
        _statuses[item.type] = result;
        _flow[item.type] =
            (_flow[item.type] ?? PermissionFlowState.initial)
                .copyWith(hasBeenAsked: true);
      });
    } finally {
      if (mounted) setState(() => _inFlight.remove(item.type));
    }
  }

  Future<void> _onOpenSettings() async {
    if (_openingSettings) return; // debounce: one open attempt at a time
    setState(() => _openingSettings = true);
    try {
      // Awaits only whether SETTINGS OPENED — never a permission result.
      // openAppSettings() resolves as soon as the page opens; the user's actual
      // change is observed by the resume re-check above when they return.
      final opened = await _service.openSettings();
      if (!opened && mounted) _showSettingsUnavailable();
    } finally {
      if (mounted) setState(() => _openingSettings = false);
    }
  }

  /// Rare fallback when the OS settings page cannot be launched: tell the user
  /// how to enable the permission by hand. (Inline copy — this repo has no l10n;
  /// move to localization when it is introduced.)
  void _showSettingsUnavailable() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text("Can't open Settings",
            style: Theme.of(context).textTheme.titleLarge),
        content: Text(
          'Open your device Settings, find ReCapture, and enable the '
          'permission under Permissions.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _onContinue() {
    Analytics.logEvent('precapture_permissions_continue', {
      'motion_granted': _statusOf(AppPermissionType.motion).isGranted,
      'photos_granted': _statusOf(AppPermissionType.photos).isGranted,
    });
    // Proceeding past the gate with an ungranted recommended/optional permission
    // is an explicit skip — persist it so the gate doesn't nag on a later visit.
    // Camera is required (it gates this CTA) and is never skipped. Fire-and-forget:
    // navigation should not wait on local persistence.
    for (final type in const [AppPermissionType.motion, AppPermissionType.photos]) {
      if (!_statusOf(type).isGranted) {
        _flowStore.markSkipped(type);
      }
    }
    context.goNamed(AppRouteNames.levelAIntro);
  }

  AppPermissionStatus _statusOf(AppPermissionType type) =>
      _statuses[type] ?? AppPermissionStatus.notRequested;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Emits the named granted event for a permission that just became granted.
  /// Camera and Motion have named events; Photos has none (documented analytics
  /// asymmetry). `user_id_hash` is omitted — the gate runs pre-auth.
  void _emitGranted(AppPermissionType type, String source) {
    switch (type) {
      case AppPermissionType.camera:
        Analytics.logEvent(
            AnalyticsEvents.permissionCameraGranted, {'source': source});
      case AppPermissionType.motion:
        // Motion is permission-free (raw IMU), so this realistically never
        // fires; wired generically for completeness.
        Analytics.logEvent(
            AnalyticsEvents.permissionMotionGranted, {'source': source});
      case AppPermissionType.photos:
        break; // no named granted event
    }
  }

  /// Emits the generic denied event with the permission, its non-granted status,
  /// and its gate criticality. Never called for `granted` or the (non-existent
  /// here) `unavailable` state.
  void _emitDenied(PermissionItem item, AppPermissionStatus status) {
    Analytics.logEvent(AnalyticsEvents.permissionDenied, {
      'permission': item.type.analyticsValue,
      'status': _deniedStatusToken(status),
      'criticality': item.requirement.analyticsValue,
    });
  }

  String _deniedStatusToken(AppPermissionStatus status) => switch (status) {
        AppPermissionStatus.permanentlyDenied => 'permanentlyDenied',
        AppPermissionStatus.restricted => 'restricted',
        // denied / notRequested both report as the re-promptable "denied".
        _ => 'denied',
      };

  bool get _cameraGranted => _statusOf(AppPermissionType.camera).isGranted;

  bool get _cameraBlocked => _statusOf(AppPermissionType.camera).needsSettings;

  bool get _motionMissing {
    final s = _statusOf(AppPermissionType.motion);
    // Respect an explicit skip: once the user has proceeded without Motion, do
    // not keep nagging. A live grant has no banner anyway, and the user can
    // still enable it via the card.
    final skipped =
        (_flow[AppPermissionType.motion] ?? PermissionFlowState.initial)
            .userSkipped;
    if (skipped) return false;
    return s == AppPermissionStatus.denied || s.needsSettings;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
        title: Text('Enable permissions', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Text(
                'ReCapture needs these to guide your capture.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: defaultPermissionItems.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final item = defaultPermissionItems[index];
                  return PermissionCard(
                    item: item,
                    status: _statusOf(item.type),
                    isInFlight: _inFlight.contains(item.type),
                    onAllow: () => _onAllow(item),
                    onOpenSettings: _onOpenSettings,
                  );
                },
              ),
            ),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cameraBlocked)
            const _InlineBanner(
              icon: Icons.error_outline,
              color: AppColors.error,
              message: 'Camera access is required to continue. '
                  'Enable it in Settings.',
            )
          else if (_motionMissing)
            const _InlineBanner(
              icon: Icons.info_outline,
              color: AppColors.warning,
              message: 'Motion access improves AR tracking. '
                  'You can continue without it.',
            ),
          if (_cameraBlocked || _motionMissing)
            const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Continue',
            // Null disables the button (greyed state) until Camera is granted.
            onPressed: _cameraGranted ? _onContinue : null,
          ),
        ],
      ),
    );
  }
}

/// `source` values for the permission granted events (mirrors the analytics
/// `PERMISSION_GRANT_SOURCES` enum).
abstract final class _GrantSource {
  static const String prompt = 'prompt';
  static const String settingsReturn = 'settings_return';
}

/// Non-blocking inline notice shown above the Continue CTA.
class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
