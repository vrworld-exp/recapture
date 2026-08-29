// lib/presentation/screens/capture/capture_preflight_gate.dart
//
// The gate that runs the capability probe BEFORE the capture screen mounts, and
// routes to a named, honest unsupported surface when something required is
// missing.
//
// It exists for one failure mode the web build can produce: a user shoots 30
// photos and only then finds out this browser could never have finished the
// job. Learning that in one screen at the start is the whole point, so the
// screen names the MISSING capability and what to do about it — never a generic
// "capture is unavailable".
//
// On Android and iOS the probe reports all-clear by construction (see
// capture_preflight_io.dart), so this wrapper is a single already-completed
// future and one build — the native flow is unchanged.
//
// The Maya/Meshy motion case is the one with a real recovery path, and it is
// deliberately gesture-driven: iOS Safari only honours
// `DeviceOrientationEvent.requestPermission()` from inside a user gesture, so
// the retry button IS the gesture. What it must never do is silently downgrade
// Meshy to an ungated shutter — the hard tilt gate is the mode's guarantee.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_mode_provider.dart';
import '../../../domain/capture/capture_mode.dart';
import '../../../domain/entities/permission_item.dart';
import '../../../platform/capture_ports/capture_preflight.dart';
import '../../../platform/permissions_service.dart';

/// Photos a mode's full job produces, for the storage-quota estimate.
///
/// These are the published, unchanged mode totals (`full` = 48 across its
/// rings, `meshy` = one ring of 6); the gate only SIZES a quota check with
/// them and never influences capture counts.
int expectedPhotoCountFor(CaptureMode mode) =>
    mode == CaptureMode.meshy ? 6 : 48;

/// Wraps a capture route with the capability probe.
class CapturePreflightGate extends ConsumerStatefulWidget {
  const CapturePreflightGate({
    super.key,
    required this.child,
    this.permissions = const PermissionsService(),
  });

  /// The capture screen to show once every required capability is present.
  final Widget child;

  /// Injected for tests; production uses the app-wide facade.
  final PermissionsService permissions;

  @override
  ConsumerState<CapturePreflightGate> createState() =>
      _CapturePreflightGateState();
}

class _CapturePreflightGateState extends ConsumerState<CapturePreflightGate> {
  Future<CapturePreflightReport>? _probe;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    if (isCapturePreflightRequired) _run();
  }

  void _run() {
    final mode = ref.read(captureModeProvider);
    setState(() {
      _probe = runCapturePreflight(
        mode: mode,
        expectedPhotoCount: expectedPhotoCountFor(mode),
      );
    });
  }

  /// Re-triggers the gesture-gated motion prompt, then re-probes.
  ///
  /// This runs inside the button's tap handler precisely so iOS Safari still
  /// sees a user gesture; moving it into `initState` or a post-frame callback
  /// would make Safari reject the request every time.
  Future<void> _requestMotion() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      await widget.permissions.request(AppPermissionType.motion);
    } finally {
      if (mounted) {
        setState(() => _requesting = false);
        _run();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Native: nothing to probe, so the gate is transparent — the capture screen
    // builds on the very first frame exactly as it did before the gate existed.
    if (!isCapturePreflightRequired) return widget.child;
    return FutureBuilder<CapturePreflightReport>(
      future: _probe,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _ProbeInProgress();
        }
        // A probe that itself threw must not block capture: it would turn a bug
        // in the check into a bug in the feature. Fail open and let the camera
        // and permission surfaces report the real problem.
        final report = snapshot.data ?? CapturePreflightReport.allClear;
        if (report.canCapture) return widget.child;
        return _UnsupportedSurface(
          key: const Key('capture_preflight_unsupported'),
          blockers: report.blockers,
          onRetry: _run,
          onRequestMotion: report.blockers
                  .any((b) => b.capability == CaptureCapability.motionSensors)
              ? _requestMotion
              : null,
          requesting: _requesting,
        );
      },
    );
  }
}

class _ProbeInProgress extends StatelessWidget {
  const _ProbeInProgress();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.surface1,
        child: Center(
          key: Key('capture_preflight_checking'),
          child: CircularProgressIndicator(),
        ),
      );
}

class _UnsupportedSurface extends StatelessWidget {
  const _UnsupportedSurface({
    super.key,
    required this.blockers,
    required this.onRetry,
    required this.requesting,
    this.onRequestMotion,
  });

  final List<CaptureCapabilityResult> blockers;
  final VoidCallback onRetry;
  final Future<void> Function()? onRequestMotion;
  final bool requesting;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.surface1,
      appBar: AppBar(title: const Text('Capture')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: AppColors.warning),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Capture can’t start on this device',
                style: textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                blockers.length == 1
                    ? 'One thing is missing:'
                    : '${blockers.length} things are missing:',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              for (final b in blockers) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child:
                          Icon(Icons.close, size: 18, color: AppColors.warning),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.capability.label, style: textTheme.titleSmall),
                          if (b.detail != null) ...[
                            const SizedBox(height: 2),
                            Text(b.detail!, style: textTheme.bodySmall),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (onRequestMotion != null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('capture_preflight_allow_motion'),
                    onPressed: requesting ? null : () => onRequestMotion!(),
                    child: Text(
                      requesting ? 'Requesting…' : 'Allow motion access',
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const Key('capture_preflight_retry'),
                  onPressed: requesting ? null : onRetry,
                  child: const Text('Check again'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
