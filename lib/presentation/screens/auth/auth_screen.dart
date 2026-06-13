// lib/presentation/screens/auth/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../platform/connectivity_watcher.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/offline_retry_modal.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isPhone = true;

  final ConnectivityWatcher _connectivity = ConnectivityWatcher();

  /// Wraps the "Send OTP" network step: if offline, surface the retry modal
  /// first; only proceed once connectivity is confirmed.
  Future<void> _onSendOtp() async {
    final status = await _connectivity.currentStatus();
    if (!mounted) return;
    if (status == AppConnectivityStatus.offline) {
      // Modal is non-dismissible, so this returns only after a successful
      // retry (device back online).
      await showOfflineRetryModal(
        context,
        source: OfflineSource.auth,
        onRetry: _ensureOnline,
      );
      if (!mounted) return;
    }
    context.go(AppRoutes.otpVerify);
  }

  Future<void> _ensureOnline() async {
    final status = await _connectivity.currentStatus();
    if (status == AppConnectivityStatus.offline) {
      throw const _OfflineException();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.huge),
            Center(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.mirageRed,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.videocam, color: Colors.white, size: 24),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text('Welcome', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Log in to start a capture.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxl),
            Row(
              children: [
                Expanded(child: _TabButton(label: 'Phone', active: _isPhone, onTap: () => setState(() => _isPhone = true))),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _TabButton(label: 'Email', active: !_isPhone, onTap: () => setState(() => _isPhone = false))),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppTextField(
              label: _isPhone ? 'Phone number' : 'Email address',
              hint: _isPhone ? '+91 98765 43210' : 'you@example.com',
              keyboardType: _isPhone ? TextInputType.phone : TextInputType.emailAddress,
            ),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: 'Send OTP',
              onPressed: _onSendOtp,
            ),
            const SizedBox(height: AppSpacing.lg),
            Center(
              child: Text(
                'By continuing you agree to our Terms and Privacy Policy',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

/// Raised when an action is attempted while the device is still offline.
class _OfflineException implements Exception {
  const _OfflineException();
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: active ? AppColors.mirageRed : AppColors.disabled,
        ),
        foregroundColor: active ? AppColors.mirageRed : AppColors.textMuted,
      ),
      child: Text(label),
    );
  }
}
