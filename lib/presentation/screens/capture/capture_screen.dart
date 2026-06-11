// lib/presentation/screens/capture/capture_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.nextRoute,
  });

  final String levelLabel;
  final String levelName;
  final String nextRoute;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with TickerProviderStateMixin {
  int _captureCount = 0;
  bool _showFlash = false;
  int _instructionIndex = 0;
  Timer? _instructionTimer;
  late final AnimationController _flashController;

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
    _instructionTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      setState(() {
        _instructionIndex = (_instructionIndex + 1) % _instructions.length;
      });
    });
  }

  @override
  void dispose() {
    _flashController.dispose();
    _instructionTimer?.cancel();
    super.dispose();
  }

  void _onShutter() {
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
      body: Stack(
        fit: StackFit.expand,
        children: [
          _CameraMockBackground(),
          _PlacementBox(),
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
            Container(
              color: Colors.white.withValues(alpha: 0.3),
            ),
        ],
      ),
    );
  }
}

class _CameraMockBackground extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      // camera mock — not a brand color
      color: const Color(0xFF0A0A0A),
      child: CustomPaint(
        painter: _GridPainter(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.disabled.withValues(alpha: 0.1)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

class _PlacementBox extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 240,
        height: 300,
        decoration: BoxDecoration(
          border: Border.all(
            color: AppColors.royalGold.withValues(alpha: 0.6),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
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
