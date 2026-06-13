// lib/presentation/screens/auth/otp_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/routes/auth_router_notifier.dart';
import 'otp_verification_screen.dart';

/// Route host for the OTP flow. Supplies the masked destination and the
/// verify/resend callbacks to [OtpVerificationScreen], keeping all auth/API
/// logic out of the screen widget.
///
/// On a successful verify it flips the auth notifier, which fires the router's
/// `refreshListenable` and redirects out of the auth flow into the Projects Hub.
///
/// TODO(auth): replace the stub callbacks with the real auth service (persist
/// the returned token via SessionStore before signIn), and pass the destination
/// through from the auth screen instead of hardcoding it.
class OtpScreen extends ConsumerWidget {
  const OtpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OtpVerificationScreen(
      destination: '+91 ••••• ••210',
      onVerify: (code) async {
        // TODO(auth): final ok = await AuthService.verifyOtp(code);
        const ok = true;
        if (ok) {
          // Flip auth → refreshListenable redirects off the OTP screen.
          ref.read(authRouterNotifierProvider).signIn();
        }
        return ok;
      },
      onResend: () async {
        // TODO(auth): await AuthService.resendOtp();
      },
    );
  }
}
