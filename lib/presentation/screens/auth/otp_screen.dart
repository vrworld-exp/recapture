// lib/presentation/screens/auth/otp_screen.dart
import 'package:flutter/material.dart';
import 'otp_verification_screen.dart';

/// Route host for the OTP flow. Supplies the masked destination and the
/// verify/resend callbacks to [OtpVerificationScreen], keeping all auth/API
/// logic out of the screen widget.
///
/// TODO(auth): replace the stub callbacks with the real auth service, and pass
/// the destination through from the auth screen instead of hardcoding it.
class OtpScreen extends StatelessWidget {
  const OtpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return OtpVerificationScreen(
      destination: '+91 ••••• ••210',
      onVerify: (code) async {
        // TODO(auth): return await AuthService.verifyOtp(code);
        return true;
      },
      onResend: () async {
        // TODO(auth): await AuthService.resendOtp();
      },
    );
  }
}
