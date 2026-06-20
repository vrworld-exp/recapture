// lib/presentation/screens/capture/capture_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/local/active_session_box.dart';
import '../../../domain/entities/permission_item.dart';
import '../../../platform/camera/camera_preview_controller.dart';
import '../../../platform/camera/camera_preview_view.dart';
import '../../../platform/camera/preview_geometry.dart';
import '../../../platform/method_channels.dart';
import '../../../platform/permissions_service.dart';
import '../../../utils/analytics.dart';
import '../../widgets/capture_overlay_layer.dart';
import '../../widgets/placement_box_overlay.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.nextRoute,
    this.permissionsService = const PermissionsService(),
    this.sessionBox,
  });

  final String levelLabel;
  final String levelName;
  final String nextRoute;

  /// Permission gateway, used to RE-CHECK camera on resume (it is granted
  /// upstream by the gate). Injectable so tests can drive a revoked status.
  final PermissionsService permissionsService;

  /// Source of the active project id for analytics. Null → the real
  /// [ActiveSessionBox]; injectable for tests. Read best-effort (never fatal).
  final ActiveSessionBox? sessionBox;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _captureCount = 0;
  bool _showFlash = false;
  int _instructionIndex = 0;
  Timer? _instructionTimer;
  late final AnimationController _flashController;

  /// Drives the native back-camera preview (CAMERA assumed granted by the P2
  /// gate). Released on dispose; stopped on background and rebound on resume.
  late final CameraPreviewController _cameraController;

  /// Triggers a native single still on the SAME bound session as the preview
  /// (CameraX ImageCapture / AVCapturePhotoOutput). Degrades gracefully: a
  /// missing/unbound session or a busy capturer resolves to null, never throws.
  final CaptureChannel _captureChannel = CaptureChannel();

  /// Guards against overlapping shutter taps while a capture is in flight (the
  /// native side also rejects with BUSY → null, but this avoids spamming it).
  bool _capturing = false;

  /// `level_a_camera_opened` is a once-per-screen reach metric.
  bool _openedLogged = false;

  /// De-dupes `level_a_camera_error`: only emit when the error code changes.
  String? _lastErrorCodeLogged;

  /// Guards against firing navigation to the permissions gate more than once.
  bool _routingToGate = false;

  /// Active project id for analytics; resolved best-effort on mount.
  String? _projectId;

  static const _instructions = [
    'Move clockwise',
    'Keep object centered',
    'Maintain distance',
    'Move slowly',
  ];

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _cameraController = CameraPreviewController();
    _cameraController.addListener(_onCameraStateChanged);
    WidgetsBinding.instance.addObserver(this);
    _resolveProjectId();
    // Start after the first frame so the engine texture registry is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cameraController.start();
    });
    _instructionTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      setState(() {
        _instructionIndex = (_instructionIndex + 1) % _instructions.length;
      });
    });
  }

  /// Best-effort read of the active project id for analytics. Never fatal — a
  /// missing/corrupt session (or an un-init Hive test host) leaves it null.
  Future<void> _resolveProjectId() async {
    try {
      final session = await (widget.sessionBox ?? ActiveSessionBox()).read();
      if (!mounted) return;
      _projectId = session?.projectId;
    } catch (_) {
      _projectId = null;
    }
  }

  /// Emits the camera analytics on state transitions (not on rebuilds):
  /// `opened` once when the preview reaches running, and `error` (de-duped by
  /// code) when the native pipeline reports a fatal error.
  void _onCameraStateChanged() {
    final state = _cameraController.value;
    if (state.status == CameraPreviewStatus.running && !_openedLogged) {
      _openedLogged = true;
      Analytics.logEvent(AnalyticsEvents.levelACameraOpened, {
        'project_id': _projectId,
        'resolution_preset': _resolutionLabel(state),
        'device_type': _deviceType,
      });
    }
    if (state.status == CameraPreviewStatus.error &&
        state.errorCode != _lastErrorCodeLogged) {
      _lastErrorCodeLogged = state.errorCode;
      Analytics.logEvent(AnalyticsEvents.levelACameraError, {
        'reason': _errorReason(state.errorCode, state.errorMessage),
        'device_type': _deviceType,
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _handleResume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _cameraController.stop();
    }
  }

  /// On foreground, RE-CHECK camera permission before rebinding: it can be
  /// revoked while backgrounded. Granted → restart the preview; revoked → emit
  /// an error event and route back to the permissions gate (never crash).
  Future<void> _handleResume() async {
    final status =
        await widget.permissionsService.status(AppPermissionType.camera);
    if (!mounted) return;
    if (status.isGranted) {
      _cameraController.start();
      return;
    }
    if (_routingToGate) return;
    _routingToGate = true;
    Analytics.logEvent(AnalyticsEvents.levelACameraError, {
      'reason': 'permission_revoked',
      'device_type': _deviceType,
    });
    context.go(AppRoutes.permissions);
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Reports the actual preview resolution (the native pipeline has no
  /// ResolutionPreset); falls back to 'unknown' before the size is known.
  String _resolutionLabel(CameraPreviewState state) =>
      state.previewWidth > 0 && state.previewHeight > 0
          ? '${state.previewWidth}x${state.previewHeight}'
          : 'unknown';

  /// Maps a native error code/message to the analytics `reason` taxonomy.
  /// `permission_revoked` is emitted explicitly from [_handleResume], not here.
  String _errorReason(String? code, String? message) {
    final c = (code ?? '').toUpperCase();
    final m = (message ?? '').toUpperCase();
    if (c.contains('NO_CAMERA') ||
        c.contains('NO_DEVICE') ||
        c == 'UNAVAILABLE' ||
        m.contains('NO CAMERA')) {
      return 'no_camera';
    }
    return 'init_failed';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController.removeListener(_onCameraStateChanged);
    _cameraController.dispose();
    _flashController.dispose();
    _instructionTimer?.cancel();
    super.dispose();
  }

  Future<void> _onShutter() async {
    if (_capturing) return;
    _capturing = true;
    // Capture a real frame on the native session before any UI feedback, so the
    // flash + counter reflect frames actually written to disk (not phantom taps).
    final frame = await _captureChannel.captureSingle();
    if (!mounted) return;
    _capturing = false;

    // Null = no bound session / busy / unsupported (e.g. permission-denied
    // preview, or a non-device test host). Keep the preview running; do not
    // advance the counter for a capture that did not happen.
    if (frame == null) return;

    setState(() {
      _showFlash = true;
      _captureCount++;
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _showFlash = false);
    });
    if (_captureCount >= 5) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) context.go(widget.nextRoute);
      });
    }
  }

  void _showExitDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          'Save and exit?',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: Text(
          'You can resume this capture anytime.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Keep Capturing'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.go(AppRoutes.projects);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.mirageRed),
            child: const Text('Save & Exit'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      // LayoutBuilder gives the on-screen size; the controller value gives the
      // native frame size/rotation. Together they form the PreviewGeometry the
      // overlay layer hands to every overlay. This rebuilds only on layout or
      // preview-state changes (not per camera frame — the Texture updates
      // independently of the widget tree).
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<CameraPreviewState>(
            valueListenable: _cameraController,
            builder: (context, state, _) {
              final geometry = PreviewGeometry.fromPreviewState(
                previewWidth: state.previewWidth,
                previewHeight: state.previewHeight,
                rotationDegrees: state.rotationDegrees,
                screenSize: constraints.biggest,
                fit: BoxFit.cover,
              );
              return CaptureOverlayLayer(
                geometry: geometry,
                cameraPreview: CameraPreview(
                  controller: _cameraController,
                  placeholder: const _CameraLoading(),
                  errorBuilder: (context, s) => _CameraErrorSurface(
                    message: s.errorMessage,
                    onRetry: _cameraController.start,
                    onBack: () => context.go(AppRoutes.projects),
                  ),
                ),
                overlays: [
                  // Render-only centre-frame guide. Status is idle until a
                  // later detection task supplies placement quality.
                  PlacementBoxOverlay(geometry: geometry),
                  _TopBar(
                    levelLabel: widget.levelLabel,
                    levelName: widget.levelName,
                    onClose: _showExitDialog,
                  ),
                  _InstructionBanner(text: _instructions[_instructionIndex]),
                  const _RingCoverageMap(),
                  const _TiltMeter(),
                  const _StabilityIndicator(),
                  _BottomBar(
                    captureCount: _captureCount,
                    onShutter: _onShutter,
                  ),
                  if (_showFlash)
                    Container(color: Colors.white.withValues(alpha: 0.3)),
                  // Debug-only: visualizes the PreviewGeometry mapping.
                  if (kDebugMode && kShowCaptureDebugReticle)
                    const CaptureDebugReticleOverlay(),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Branded loading state shown while the preview is being acquired (Deep Black +
/// spinner). Replaces the controller's plain black placeholder.
class _CameraLoading extends StatelessWidget {
  const _CameraLoading();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.bgPrimary,
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.mirageRed,
          ),
        ),
      ),
    );
  }
}

/// Branded camera-error state with retry + back, on Deep Black. Shown when the
/// native pipeline reports a fatal error (init failed, camera in use, no camera).
class _CameraErrorSurface extends StatelessWidget {
  const _CameraErrorSurface({
    required this.onRetry,
    required this.onBack,
    this.message,
  });

  final VoidCallback onRetry;
  final VoidCallback onBack;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bgPrimary,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off,
                  color: AppColors.textSecondary, size: 44),
              const SizedBox(height: AppSpacing.lg),
              Text(
                message ?? 'Camera unavailable',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: onBack,
                    child: Text(
                      'Back',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  ElevatedButton(
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.levelLabel,
    required this.levelName,
    required this.onClose,
  });

  final String levelLabel;
  final String levelName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: onClose,
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface1,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  '$levelLabel • $levelName',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.textPrimary),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.help_outline, color: Colors.white),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructionBanner extends StatelessWidget {
  const _InstructionBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.30,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface1.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _RingCoverageMap extends StatelessWidget {
  const _RingCoverageMap();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: AppSpacing.lg,
      bottom: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const CircularProgressIndicator(
                  value: 0.68,
                  strokeWidth: 6,
                  backgroundColor: AppColors.surface2,
                  color: AppColors.mirageRed,
                ),
                Text(
                  '68%',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TiltMeter extends StatelessWidget {
  const _TiltMeter();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: AppSpacing.lg,
      top: 150,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Tilt',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            width: 8,
            height: 120,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Positioned(
                  top: 120 * 0.4,
                  left: 0,
                  right: 0,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.mirageRed,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StabilityIndicator extends StatelessWidget {
  const _StabilityIndicator();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: AppSpacing.lg,
      bottom: 108,
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            'Stable',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.captureCount, required this.onShutter});

  final int captureCount;
  final VoidCallback onShutter;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          height: 100,
          color: AppColors.surface1.withValues(alpha: 0.9),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: List.generate(
                  3,
                  (i) => Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              GestureDetector(
                key: const ValueKey('capture_shutter'),
                onTap: onShutter,
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.textPrimary, width: 3),
                  ),
                  child: Center(
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: const BoxDecoration(
                        color: AppColors.mirageRed,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${captureCount + 12}/36',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.white),
                  ),
                  Text(
                    'Auto: ON',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
