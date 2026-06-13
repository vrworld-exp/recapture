// lib/presentation/screens/capture/permissions_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
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
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  static const _service = PermissionsService();

  final Map<AppPermissionType, AppPermissionStatus> _statuses = {
    for (final item in defaultPermissionItems)
      item.type: AppPermissionStatus.notRequested,
  };

  /// Per-permission in-flight guard — blocks duplicate OS prompts from a
  /// rapid double-tap on "Allow".
  final Set<AppPermissionType> _inFlight = <AppPermissionType>{};

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
    // change the user made outside the app.
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    final results = <AppPermissionType, AppPermissionStatus>{};
    for (final item in defaultPermissionItems) {
      results[item.type] = await _service.status(item.type);
    }
    if (!mounted) return;
    setState(() => _statuses.addAll(results));
  }

  Future<void> _onAllow(PermissionItem item) async {
    if (_inFlight.contains(item.type)) return; // double-tap guard
    setState(() => _inFlight.add(item.type));
    try {
      final result = await _service.request(item.type);
      Analytics.logEvent('precapture_permission_result', {
        'permission_type': item.type.analyticsValue,
        'result': result.analyticsValue,
        'requirement': item.requirement.analyticsValue,
        'device_type': _deviceType,
      });
      if (!mounted) return;
      setState(() => _statuses[item.type] = result);
    } finally {
      if (mounted) setState(() => _inFlight.remove(item.type));
    }
  }

  Future<void> _onOpenSettings() => _service.openSettings();

  void _onContinue() {
    Analytics.logEvent('precapture_permissions_continue', {
      'motion_granted': _statusOf(AppPermissionType.motion).isGranted,
      'photos_granted': _statusOf(AppPermissionType.photos).isGranted,
    });
    context.go(AppRoutes.levelAIntro);
  }

  AppPermissionStatus _statusOf(AppPermissionType type) =>
      _statuses[type] ?? AppPermissionStatus.notRequested;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  bool get _cameraGranted => _statusOf(AppPermissionType.camera).isGranted;

  bool get _cameraBlocked => _statusOf(AppPermissionType.camera).needsSettings;

  bool get _motionMissing {
    final s = _statusOf(AppPermissionType.motion);
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
