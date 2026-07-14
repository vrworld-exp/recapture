// lib/presentation/screens/auth/auth_screen.dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/otp_request.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../domain/auth/auth_input_validators.dart';
import '../../../domain/entities/country_code.dart';
import '../../../platform/connectivity_watcher.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/country_code_picker.dart';
import '../../widgets/offline_retry_modal.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, this.connectivity});

  /// Injectable connectivity gate for tests; null → the real watcher.
  final ConnectivityWatcher? connectivity;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _isPhone = true;

  late final ConnectivityWatcher _connectivity =
      widget.connectivity ?? ConnectivityWatcher();

  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();

  /// Selected dial code for the phone tab. Defaults to India (+91); changed
  /// via the flag button → country sheet.
  CountryCode _country = kDefaultCountryCode;

  /// Inline validation errors, per tab. Set on a Send OTP attempt, cleared as
  /// soon as the user edits the field again (validate-on-submit).
  String? _phoneError;
  String? _emailError;

  /// Double-tap guard around the send-otp network step. Also drives the
  /// Send OTP button's spinner/disabled state while the request is pending.
  bool _sending = false;

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  /// The normalized identifier for the active tab: E.164 phone (dial code +
  /// national digits) or trimmed, lowercased email — matching the backend's
  /// own normalization so send and verify always address the same record.
  String get _identifier => _isPhone
      ? '${_country.dialCode}${_phoneController.text.trim()}'
      : _emailController.text.trim().toLowerCase();

  String get _channel => _isPhone ? 'sms' : 'email';

  /// Wraps the "Send OTP" step: validate the active tab's input first
  /// (invalid → inline error, no network), confirm connectivity (offline →
  /// retry modal), then dispatch the real send-otp. Only a successful
  /// dispatch installs the OTP request and navigates to the OTP screen.
  Future<void> _onSendOtp() async {
    if (_sending || !_validateActiveTab()) return;
    setState(() => _sending = true);
    try {
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

      final OtpSendResult result;
      try {
        result = await ref.read(authRepositoryProvider).sendOtp(
              channel: _channel,
              identifier: _identifier,
            );
      } on OtpRateLimitedException catch (e) {
        _setActiveTabError(
          'Too many attempts — try again in ${e.retryAfterSeconds ?? 60}s.',
        );
        return;
      } on DioException {
        // Transport/server failure → the shared retry modal; it closes only
        // after a retry that resolves (dispatch succeeded).
        if (!mounted) return;
        OtpSendResult? retried;
        await showOfflineRetryModal(
          context,
          source: OfflineSource.auth,
          onRetry: () async {
            retried = await ref.read(authRepositoryProvider).sendOtp(
                  channel: _channel,
                  identifier: _identifier,
                );
          },
        );
        if (retried == null || !mounted) return;
        _installAndGo(retried!);
        return;
      }
      if (!mounted) return;
      _installAndGo(result);
    } finally {
      // _installAndGo may have navigated away; only repaint if still here.
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Publishes the dispatched request (destination + dev echo) for the OTP
  /// screen, then navigates.
  void _installAndGo(OtpSendResult result) {
    ref.read(otpRequestProvider.notifier).set(OtpRequest(
          channel: _channel,
          identifier: _identifier,
          devCode: result.devCode,
        ));
    context.goNamed(AppRouteNames.otpVerify);
  }

  void _setActiveTabError(String message) {
    if (!mounted) return;
    setState(() {
      if (_isPhone) {
        _phoneError = message;
      } else {
        _emailError = message;
      }
    });
  }

  /// Runs the pure validator for the visible tab and installs/clears its
  /// inline error. Returns true when the input may proceed to the OTP step.
  bool _validateActiveTab() {
    if (_isPhone) {
      final error = AuthInputValidators.phone(
        _phoneController.text,
        country: _country,
      );
      setState(() => _phoneError = error);
      return error == null;
    }
    final error = AuthInputValidators.email(_emailController.text);
    setState(() => _emailError = error);
    return error == null;
  }

  Future<void> _pickCountry() async {
    final picked = await showCountryCodePicker(context, selected: _country);
    if (picked == null || !mounted) return;
    setState(() {
      _country = picked;
      // The old error may not apply under the new country's rules; the next
      // Send OTP attempt re-validates.
      _phoneError = null;
    });
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
            if (_isPhone)
              // Two-part phone input: dial-code selector (flag + code, default
              // 🇮🇳 +91) + the national number. The button aligns with the
              // field's input box, so errors render below without moving it.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CountryCodeButton(
                    country: _country,
                    onPressed: _pickCountry,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppTextField(
                      key: const ValueKey('auth_phone_field'),
                      label: 'Phone number',
                      hint: '98765 43210',
                      controller: _phoneController,
                      errorText: _phoneError,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      // E.164 caps the significant digits at 15; the validator
                      // enforces the tighter per-country rule (10 for +91).
                      maxLength: 15,
                      onChanged: (_) {
                        if (_phoneError != null) {
                          setState(() => _phoneError = null);
                        }
                      },
                    ),
                  ),
                ],
              )
            else
              AppTextField(
                key: const ValueKey('auth_email_field'),
                label: 'Email address',
                hint: 'you@example.com',
                controller: _emailController,
                errorText: _emailError,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) {
                  if (_emailError != null) {
                    setState(() => _emailError = null);
                  }
                },
              ),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: 'Send OTP',
              isLoading: _sending,
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
