// lib/presentation/screens/auth/otp_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/placeholder_box.dart';

class OtpScreen extends StatelessWidget {
  const OtpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Enter OTP'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.xxl),
              Text('Enter OTP', style: tt.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text('Sent to +91 •••• 3210', style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.xxxl),
              const PlaceholderBox(
                label: 'OTP Input — 6 digit boxes',
                height: 64,
                icon: Icons.pin_outlined,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Resend in ', style: tt.bodySmall),
                  Text(
                    '00:23',
                    style: tt.bodySmall?.copyWith(color: AppColors.mirageRed),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.huge),
              AppButton(
                label: 'Verify',
                onPressed: () => context.go(AppRoutes.projects),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                label: 'Change number',
                onPressed: () => context.pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
