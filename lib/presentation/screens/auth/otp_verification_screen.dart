// lib/presentation/screens/auth/otp_verification_screen.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../platform/haptics.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/offline_retry_modal.dart';

/// Number of OTP digits. Single source of truth — change here if the backend
/// uses a different length.
const int kOtpLength = 6;

/// Resend cooldown in seconds. Confirm against the backend's resend rate limit.
const int kResendCooldownSeconds = 30;

/// OTP verification screen for the Auth flow. Renders [kOtpLength] boxes driven
/// by a single hidden field (robust for paste + Android SMS autofill), with
/// auto-submit, a gated resend countdown, and offline/retry handling.
///
/// All API/auth logic stays in the injected callbacks — this widget never
/// talks to a service directly.
class OtpVerificationScreen extends StatefulWidget {
  const OtpVerificationScreen({
    required this.destination,
    required this.onVerify,
    required this.onResend,
    super.key,
  });

  /// Masked phone/email the code was sent to (prepared by the caller).
  final String destination;

  /// Returns true on success, false on an invalid code, throws on network error.
  final Future<bool> Function(String code) onVerify;

  /// Re-sends the code. Throws on network error.
  final Future<void> Function() onResend;

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Length of the field on the previous change — used to distinguish a paste
  /// (multi-char jump) from single-digit typing, and to fire auto-submit once.
  int _prevLength = 0;

  /// Single in-flight guard — blocks auto-submit and the manual Verify tap from
  /// running two verifies at once.
  bool _verifyInFlight = false;
  bool _verifying = false;
  String? _error;

  Timer? _timer;
  int _secondsRemaining = kResendCooldownSeconds;
  bool _resending = false;
  int _resendCount = 0;

  /// Captured retry outcome so navigation/error happens after the offline modal
  /// closes (never while it is still on top of the navigator).
  bool? _retryOutcome;

  String get _code => _controller.text;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _startTimer() {
    _timer?.cancel();
    setState(() => _secondsRemaining = kResendCooldownSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_secondsRemaining <= 1) {
        _timer?.cancel();
        setState(() => _secondsRemaining = 0);
      } else {
        setState(() => _secondsRemaining--);
      }
    });
  }

  // ── Input ────────────────────────────────────────────────────────────────────

  void _onChanged(String value) {
    final oldLength = _prevLength;
    _prevLength = value.length;
    setState(() => _error = null); // editing clears any previous error
    if (value.length == kOtpLength && oldLength < kOtpLength) {
      // Distinguish a paste / SMS autofill (multi-char jump) from typing.
      final method = (value.length - oldLength) > 1 ? 'paste' : 'auto_submit';
      _handleVerify(method);
    }
  }

  void _clearAndRefocus() {
    _controller.clear();
    _prevLength = 0;
    if (mounted) setState(() {});
    _focusNode.requestFocus();
  }

  // ── Verify ───────────────────────────────────────────────────────────────────

  Future<void> _handleVerify(String method) async {
    if (_verifyInFlight) return; // double-fire guard
    _verifyInFlight = true;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final ok = await widget.onVerify(_code);
      if (!mounted) return;
      _resolveOutcome(ok, method);
    } catch (_) {
      _logAttempt('network_error', method);
      if (!mounted) return;
      setState(() => _verifying = false);
      _retryOutcome = null;
      await showOfflineRetryModal(
        context,
        source: OfflineSource.auth,
        onRetry: () async {
          // Throws on network → modal stays open. Returns → modal dismisses.
          final ok = await widget.onVerify(_code);
          _retryOutcome = ok;
          _logAttempt(ok ? 'success' : 'invalid', method);
        },
      );
      // Modal closed (network restored) — act on the captured outcome now that
      // the dialog is no longer on top of the navigator.
      if (!mounted) return;
      if (_retryOutcome != null) {
        _resolveOutcome(_retryOutcome!, method, alreadyLogged: true);
      }
    } finally {
      _verifyInFlight = false;
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _resolveOutcome(bool ok, String method, {bool alreadyLogged = false}) {
    if (!alreadyLogged) _logAttempt(ok ? 'success' : 'invalid', method);
    if (!mounted) return;
    if (ok) {
      context.goNamed(AppRouteNames.projects);
    } else {
      Haptics.failed();
      _clearAndRefocus();
      setState(() => _error = 'Incorrect code, try again');
    }
  }

  void _logAttempt(String result, String method) {
    Analytics.logEvent('otp_verify_attempt', {
      'result': result,
      'method': method,
      'device_type': _deviceType,
    });
  }

  // ── Resend ───────────────────────────────────────────────────────────────────

  Future<void> _handleResend() async {
    if (_secondsRemaining > 0 || _resending) return; // gated + double-tap guard
    _resending = true;
    _resendCount++;
    Analytics.logEvent('otp_resend', {'attempt_number': _resendCount});
    try {
      await widget.onResend();
      if (!mounted) return;
      _clearAndRefocus();
      _startTimer();
    } catch (_) {
      if (!mounted) return;
      await showOfflineRetryModal(
        context,
        source: OfflineSource.auth,
        onRetry: widget.onResend,
      );
      // Resend succeeded via the modal (it only closes on success).
      if (!mounted) return;
      _clearAndRefocus();
      _startTimer();
    } finally {
      _resending = false;
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isComplete = _code.length == kOtpLength;

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
              'Sent to ${widget.destination}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxxl),
            _buildOtpInput(),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.error),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            _buildResend(),
            const SizedBox(height: AppSpacing.huge),
            AppButton(
              label: 'Verify',
              isLoading: _verifying,
              onPressed: isComplete ? () => _handleVerify('manual') : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOtpInput() {
    final activeIndex =
        _code.length >= kOtpLength ? kOtpLength - 1 : _code.length;

    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          // Interactive, visually transparent field — the real input. The
          // oneTimeCode hint lets Android SMS autofill populate it.
          Positioned.fill(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              enableInteractiveSelection: false,
              showCursor: false,
              cursorColor: Colors.transparent,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(kOtpLength),
              ],
              style: const TextStyle(color: Colors.transparent, height: 0.1),
              decoration: const InputDecoration(
                border: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: _onChanged,
            ),
          ),
          // Rendered boxes — ignore pointer so taps reach the field behind.
          IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(kOtpLength, (i) {
                return _OtpBox(
                  char: i < _code.length ? _code[i] : '',
                  focused: _focusNode.hasFocus && i == activeIndex,
                  hasError: _error != null,
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResend() {
    if (_secondsRemaining > 0) {
      return Text(
        'Resend in ${_secondsRemaining}s',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.textMuted),
      );
    }
    return TextButton(
      onPressed: _handleResend,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.mirageRed,
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('Resend code'),
    );
  }
}

/// A single OTP digit box.
class _OtpBox extends StatelessWidget {
  const _OtpBox({
    required this.char,
    required this.focused,
    required this.hasError,
  });

  final String char;
  final bool focused;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final Color borderColor;
    if (hasError) {
      borderColor = AppColors.error;
    } else if (focused) {
      borderColor = AppColors.mirageRed;
    } else {
      borderColor = AppColors.disabled;
    }

    return Container(
      width: 48,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Text(
        char,
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(color: AppColors.textPrimary),
      ),
    );
  }
}
