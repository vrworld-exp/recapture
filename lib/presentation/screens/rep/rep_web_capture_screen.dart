// lib/presentation/screens/rep/rep_web_capture_screen.dart
//
// Six photos of one dish, taken in a browser.
//
// ── WHAT THIS IS NOT ────────────────────────────────────────────────────────
// It is NOT the 6-photo ring. The ring fills by measured yaw: the phone knows
// which of the six wedges the rep is standing in, and will not accept a second
// shot from the same one. There is no yaw here — a laptop has no gyroscope —
// so this screen cannot verify a single thing about where the rep is standing.
//
// THAT CHANGES WHAT THE SCREEN OWES THE REP. A guided capture can afford to
// stay quiet, because it will stop you when you are wrong. This one cannot, so
// it says the quiet part out loud on every shot ("take a step to your left")
// and tells the rep plainly, once, that nothing is checking. Dressing it up
// with a ring graphic that fills on a TAP rather than on a measured position
// would be the one genuinely dishonest option: it would look like verification.
//
// ── WHY SIX, THEN ───────────────────────────────────────────────────────────
// Because six is what the pipeline behind it already expects — `CaptureMode`
// .meshy is "ONE ring of 6, shutter only", and its model selector picks the
// best 4. Six manual shots is the ONE shape the browser can produce that the
// existing backend already understands, which is why the flow is built around
// it rather than around "as many photos as you like".
//
// The upload, and everything true about the manifest it writes, is in
// web_capture_upload.dart.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/rep/web_capture_upload.dart';
import '../../../application/rep/web_dish_camera.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

/// How many shots the meshy pipeline expects. Not a tuning knob — see the
/// header.
const int kWebCaptureShotCount = 6;

/// Opens the browser capture flow. Resolves true once a job is QUEUED, or null
/// when the rep backed out.
Future<bool?> showRepWebCapture(BuildContext context, {required String dishName}) =>
    Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RepWebCaptureScreen(dishName: dishName),
      ),
    );

class RepWebCaptureScreen extends ConsumerStatefulWidget {
  const RepWebCaptureScreen({super.key, required this.dishName});

  /// Names the PROJECT the capture creates, so the rep can recognise it in the
  /// picker afterwards. A capture called "Untitled" is unfindable in a list of
  /// six of them.
  final String dishName;

  @override
  ConsumerState<RepWebCaptureScreen> createState() =>
      _RepWebCaptureScreenState();
}

class _RepWebCaptureScreenState extends ConsumerState<RepWebCaptureScreen> {
  WebDishCamera? _camera;
  final List<Uint8List> _shots = [];

  bool _starting = true;
  bool _uploading = false;
  String? _failure;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // Fire-and-forget: dispose cannot await, and a stream left running is the
    // one failure here with a visible symptom — the camera light stays on.
    _camera?.stop();
    super.dispose();
  }

  Future<void> _start() async {
    final camera = ref.read(webDishCameraFactoryProvider)();
    try {
      await camera.start();
      if (!mounted) {
        await camera.stop();
        return;
      }
      setState(() {
        _camera = camera;
        _starting = false;
      });
    } on WebDishCameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _failure = error.message;
      });
    }
  }

  Future<void> _shoot() async {
    final camera = _camera;
    if (camera == null || _shots.length >= kWebCaptureShotCount) return;
    try {
      final bytes = await camera.grabFrame();
      if (!mounted) return;
      setState(() => _shots.add(bytes));
    } on WebDishCameraException catch (error) {
      if (!mounted) return;
      setState(() => _failure = error.message);
    }
  }

  /// Drops the last shot. The only edit offered, and enough: a rep who notices
  /// a bad frame notices it immediately, and "retake the last one" covers that
  /// without a gallery, a per-shot picker, or a way to end up with five.
  void _undo() {
    if (_shots.isEmpty) return;
    setState(() => _shots.removeLast());
  }

  Future<void> _finish() async {
    if (_shots.length < kWebCaptureShotCount || _uploading) return;

    setState(() {
      _uploading = true;
      _failure = null;
      _progress = 0;
    });

    // Release the device BEFORE the upload: the photos are already in memory,
    // and holding the camera through a slow upload leaves the light on for no
    // reason.
    await _camera?.stop();

    try {
      await ref.read(webCaptureUploaderProvider).upload(
            projectName: widget.dishName,
            photos: [
              for (var i = 0; i < _shots.length; i++)
                WebCapturePhoto(segmentIndex: i, bytes: _shots[i]),
            ],
            onProgress: (sent, total) {
              if (!mounted || total <= 0) return;
              setState(() => _progress = sent / total);
            },
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        // Deliberately one message for every upload failure. The rep's move is
        // the same in all of them — try again on a better connection — and the
        // photos are still in memory, so retrying costs nothing.
        _failure = "Those photos couldn't be uploaded. Check your connection "
            'and try again — your six shots are still here.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(_uploading ? 'Uploading' : 'Capture the dish'),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_starting) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_camera == null) {
      return _CameraUnavailable(
        message: _failure ?? 'The camera could not be started.',
        onBack: () => Navigator.of(context).pop(),
      );
    }
    if (_uploading) {
      return _UploadingView(progress: _progress);
    }

    final done = _shots.length;
    final complete = done >= kWebCaptureShotCount;

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _camera!.preview(),
              // The instruction sits ON the preview, because that is where the
              // rep is looking while they decide where to stand.
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: _Instruction(shotIndex: done, complete: complete),
                ),
              ),
            ],
          ),
        ),
        Container(
          color: AppColors.bgPrimary,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: [
              _ShotDots(taken: done, total: kWebCaptureShotCount),
              const SizedBox(height: AppSpacing.md),
              if (_failure != null) ...[
                Text(
                  _failure!,
                  key: const ValueKey('rep_web_capture_error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.error),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              Row(
                children: [
                  Expanded(
                    child: AppButton.secondary(
                      label: 'Retake last',
                      onPressed: done == 0 ? null : _undo,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: complete
                        ? AppButton(
                            key: const ValueKey('rep_web_capture_finish'),
                            label: 'Use these 6',
                            onPressed: _finish,
                          )
                        : AppButton(
                            key: const ValueKey('rep_web_capture_shutter'),
                            label: 'Take photo ${done + 1}',
                            onPressed: _shoot,
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What to do before the next shot.
class _Instruction extends StatelessWidget {
  const _Instruction({required this.shotIndex, required this.complete});

  final int shotIndex;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final text = complete
        ? 'Six photos taken. Check the last one looked right, then continue.'
        : shotIndex == 0
            // The honesty note lands ONCE, on the first shot, where it is
            // information rather than nagging.
            ? 'Fill the frame with the dish, then take the first photo.\n'
                'Nothing here checks your angle — the spacing is up to you.'
            : 'Move about a sixth of the way around the dish, keeping it in '
                'frame.';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          text,
          key: const ValueKey('rep_web_capture_instruction'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

/// Six dots — how many are taken, how many remain.
///
/// Dots rather than a RING on purpose: a ring is the guided capture's own
/// symbol, and it means "this wedge is covered", which is a claim this flow
/// cannot make. A row of dots only counts, which is all that is true here.
class _ShotDots extends StatelessWidget {
  const _ShotDots({required this.taken, required this.total});

  final int taken;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < taken ? AppColors.royalGold : Colors.transparent,
                border: Border.all(
                  color: i < taken ? AppColors.royalGold : AppColors.textMuted,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UploadingView extends StatelessWidget {
  const _UploadingView({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LinearProgressIndicator(
            value: progress == 0 ? null : progress.clamp(0.0, 1.0),
            backgroundColor: AppColors.surface1,
            color: AppColors.royalGold,
          ),
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'Sending the photos. The 3D model starts building on its own once '
            'this finishes.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bgPrimary,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              size: 40,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              key: const ValueKey('rep_web_capture_unavailable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            // The way out is never a dead end: a photo dish needs no camera at
            // all, and it is one screen back.
            const Text(
              'You can still add this dish from a photo instead.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(label: 'Go back', onPressed: onBack),
          ],
        ),
      ),
    );
  }
}
