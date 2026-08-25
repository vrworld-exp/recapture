// lib/application/auth/otp_request.dart
//
// The in-flight OTP request: which identifier the code was sent to (and over
// which channel), plus the DEV-ONLY echoed code when the backend is running in
// development mode. Set by the auth screen on a successful send-otp, read by
// the OTP screen (real destination + verify/resend bodies + dev autofill
// chip), cleared on a successful login.
//
// Never persisted — process memory only. The devCode is a real credential
// while valid; it must never touch storage, logs, or analytics.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One dispatched OTP: destination + optional dev echo.
class OtpRequest {
  const OtpRequest({
    required this.channel,
    required this.identifier,
    this.devCode,
  });

  /// 'sms' or 'email' — mirrors the backend's discriminated union.
  final String channel;

  /// The normalized identifier the code went to: E.164 phone ('+9198…') or
  /// lowercased email.
  final String identifier;

  /// The OTP echoed by a NODE_ENV=development backend. Null in production —
  /// the dev chip on the OTP screen renders only when this is present.
  final String? devCode;

  OtpRequest copyWith({String? devCode}) => OtpRequest(
        channel: channel,
        identifier: identifier,
        devCode: devCode ?? this.devCode,
      );

  /// Display-masked destination, safe for the OTP screen's "Sent to …" line:
  /// phone keeps the dial prefix + last 3 digits; email keeps the first
  /// character + domain.
  String get maskedDestination {
    if (channel == 'email') {
      final at = identifier.indexOf('@');
      if (at <= 0) return '•••';
      return '${identifier[0]}•••${identifier.substring(at)}';
    }
    if (identifier.length <= 6) return identifier;
    final head = identifier.substring(0, 3);
    final tail = identifier.substring(identifier.length - 3);
    return '$head ••••• ••$tail';
  }
}

class OtpRequestNotifier extends Notifier<OtpRequest?> {
  @override
  OtpRequest? build() => null;

  /// Installs the request after a successful send-otp.
  void set(OtpRequest request) => state = request;

  /// A resend may mint a NEW code — replace the dev echo (or clear it when the
  /// resend carried none).
  void updateDevCode(String? devCode) {
    final current = state;
    if (current == null) return;
    state = OtpRequest(
      channel: current.channel,
      identifier: current.identifier,
      devCode: devCode,
    );
  }

  /// Drops the request (successful login, or leaving the flow).
  void clear() => state = null;
}

/// The pending OTP request, or null when none was dispatched this session.
final otpRequestProvider = NotifierProvider<OtpRequestNotifier, OtpRequest?>(
  OtpRequestNotifier.new,
);
