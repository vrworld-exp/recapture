// lib/presentation/screens/auth/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/app_text_field.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: '', showBack: false),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.huge),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.mirageRed,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(Icons.videocam_rounded,
                    size: 24, color: Colors.white),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Text('Welcome', style: tt.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text('Log in to start a capture.', style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.xxl),
              // Tab selector — Phone active (static skeleton)
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface1,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  border: Border.all(color: AppColors.disabled, width: 0.5),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                                color: AppColors.mirageRed, width: 2),
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                              vertical: AppSpacing.sm),
                          child: Text(
                            'Phone',
                            style: TextStyle(
                              fontSize: AppTypography.sizeBody,
                              fontWeight: FontWeight.w500,
                              color: AppColors.mirageRed,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                            vertical: AppSpacing.sm),
                        child: Text(
                          'Email',
                          style: TextStyle(
                            fontSize: AppTypography.sizeBody,
                            fontWeight: FontWeight.w400,
                            color: AppColors.textMuted,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const AppTextField(
                label: 'Phone number',
                hint: '+91 98765 43210',
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                label: 'Send OTP',
                onPressed: () => context.go(AppRoutes.otpVerify),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'By continuing you agree to our Terms and Privacy Policy.',
                style: tt.bodySmall?.copyWith(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          ),
        ),
      ),
    );
  }
}
