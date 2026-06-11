// lib/presentation/screens/auth/otp_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  int _secondsLeft = 23;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_secondsLeft > 0) {
        setState(() => _secondsLeft--);
      } else {
        _timer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timerText {
    final mins = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final secs = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
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
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.xxl),
            Text('Enter OTP', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Sent to +91 •••• 3210',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxxl),
            _OtpBoxRow(),
            const SizedBox(height: AppSpacing.lg),
            if (_secondsLeft > 0)
              Text(
                'Resend in $_timerText',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              )
            else
              TextButton(
                onPressed: () => setState(() => _secondsLeft = 23),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.mirageRed,
                  padding: EdgeInsets.zero,
                ),
                child: const Text('Resend OTP'),
              ),
            const SizedBox(height: AppSpacing.huge),
            AppButton(
              label: 'Verify',
              onPressed: () => context.go(AppRoutes.projects),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtpBoxRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(6, (i) {
        final isActive = i == 3;
        final hasDot = i < 3;
        return Container(
          width: 48,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(
              color: isActive ? AppColors.mirageRed : AppColors.disabled,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: hasDot
              ? Text(
                  '•',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: AppColors.textPrimary),
                )
              : null,
        );
      }),
    );
  }
}
