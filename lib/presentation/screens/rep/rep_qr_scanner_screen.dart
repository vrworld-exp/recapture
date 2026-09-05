// lib/presentation/screens/rep/rep_qr_scanner_screen.dart
//
// The in-app standee scanner. ONE screen, every target — android, ios, macos
// and the browser — because `mobile_scanner` carries its own web
// implementation (see the justification in pubspec.yaml).
//
// IT POPS A CODE, NOT A BARCODE. The camera sees whatever is in front of it,
// and most of that is not ours: a menu's own QR, a payment sticker, a wifi
// card on the next table. Every detection is run through `QrCodeInput.normalize`
// — the SAME parser manual entry uses, so a scan and a typed code cannot
// disagree — and anything that is not one of our 8-character codes is IGNORED
// rather than returned. A scanner that pops junk back into the activation flow
// would fail one screen later, in front of a restaurant owner, with an error
// about a code the rep never typed.
//
// It resolves to `String?`: the normalised code, or null when the rep backed
// out. The caller treats null as "carry on typing" — the field is always there,
// which is why nothing here needs a failure path back to the activation screen.
//
// THE CAMERA IS NOT THE CAPTURE PIPELINE. This is a short-lived preview owned
// by the plugin and disposed with the route. It shares no channel, no storage
// and no permission plumbing with the 6-photo ring in lib/platform/camera.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/rep/qr_code_input.dart';
import '../../widgets/app_button.dart';

/// Opens the scanner and resolves to a normalised standee code, or null when
/// the rep dismissed it.
///
/// The one way in. Callers never construct the screen themselves, so the
/// "pops a normalised code or null" contract has a single place to hold.
Future<String?> showRepQrScanner(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const RepQrScannerScreen(),
      ),
    );

class RepQrScannerScreen extends StatefulWidget {
  const RepQrScannerScreen({super.key});

  @override
  State<RepQrScannerScreen> createState() => _RepQrScannerScreenState();
}

class _RepQrScannerScreenState extends State<RepQrScannerScreen> {
  // QR ONLY. Left at every format the scanner would also lock onto EAN and
  // Code128 — a barcode on the underside of the standee, or on anything else on
  // the table — and spend its detection budget rejecting them.
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// Set once a code has been accepted, so the pop happens EXACTLY once.
  /// `noDuplicates` suppresses repeats of the same value, not a second distinct
  /// code arriving in the frame after we have already decided to leave.
  bool _handled = false;

  /// A QR was read and it was not one of ours. Shown as a hint rather than an
  /// error: the rep is probably pointing at the restaurant's own menu code, and
  /// the fix is to move the camera, not to leave the screen.
  bool _sawForeignCode = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      // Accepts a bare code, a hyphenated or lowercase one, and a full
      // resolver URL — which is exactly what a standee's QR actually encodes.
      final code = QrCodeInput.normalize(raw);
      if (code == null) continue;

      _handled = true;
      Navigator.of(context).pop(code);
      return;
    }

    // Nothing in the frame was ours.
    if (!_sawForeignCode && capture.barcodes.isNotEmpty && mounted) {
      setState(() => _sawForeignCode = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Scan the standee'),
        actions: [
          // Torch state comes from the controller, so a target that has no
          // torch (every browser, most laptops) renders nothing rather than a
          // button that does nothing.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable) {
                return const SizedBox.shrink();
              }
              final on = state.torchState == TorchState.on;
              return IconButton(
                key: const ValueKey('rep_scanner_torch'),
                icon: Icon(on ? Icons.flash_on : Icons.flash_off),
                onPressed: () => _controller.toggleTorch(),
              );
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            key: const ValueKey('rep_scanner_view'),
            controller: _controller,
            onDetect: _onDetect,
            // A camera that will never start is a DEAD END unless the screen
            // says so and offers the way out. Denied permission, no camera, an
            // insecure origin in the browser — all land here, and all get the
            // same answer: go back and type it.
            errorBuilder: (context, error) => _ScannerUnavailable(
              message: _messageFor(error),
              onEnterByHand: () => Navigator.of(context).pop(),
            ),
          ),
          _ScannerGuide(sawForeignCode: _sawForeignCode),
        ],
      ),
    );
  }

  /// Plugin errors, answered in this screen's own words. A rep never reads a
  /// package's sentence — the same rule the activation screen follows for
  /// backend failures.
  static String _messageFor(MobileScannerException error) =>
      switch (error.errorCode) {
        MobileScannerErrorCode.permissionDenied =>
          'This app does not have camera access yet. Allow the camera in your '
              'settings, or go back and type the code instead.',
        MobileScannerErrorCode.unsupported =>
          'This device or browser cannot open a scanner. Go back and type the '
              '8-character code instead — it works everywhere.',
        _ => 'The camera could not start. Go back and type the 8-character '
            'code instead.',
      };
}

/// The framing box and the standing instruction.
class _ScannerGuide extends StatelessWidget {
  const _ScannerGuide({required this.sawForeignCode});

  final bool sawForeignCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        children: [
          const Spacer(),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.royalGold, width: 2),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              sawForeignCode
                  // Names what went wrong WITHOUT calling it an error, because
                  // nothing failed: the rep is pointing at the wrong square.
                  ? "That QR is not a standee code. Point at the square on the "
                      "ReCapture standee."
                  : 'Point the camera at the QR square on the standee.',
              key: const ValueKey('rep_scanner_hint'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: sawForeignCode ? AppColors.royalGold : Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the preview when the camera will not start at all.
class _ScannerUnavailable extends StatelessWidget {
  const _ScannerUnavailable({
    required this.message,
    required this.onEnterByHand,
  });

  final String message;
  final VoidCallback onEnterByHand;

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
              Icons.no_photography_outlined,
              size: 40,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              key: const ValueKey('rep_scanner_unavailable'),
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: 'Type the code instead',
              onPressed: onEnterByHand,
            ),
          ],
        ),
      ),
    );
  }
}
