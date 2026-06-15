// lib/presentation/screens/auth/otp_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/auth/auth_notifier.dart';
import '../../../data/repositories/auth_repository.dart';
import 'otp_verification_screen.dart';

/// Route host for the OTP flow. Supplies the masked destination and the
/// verify/resend callbacks to [OtpVerificationScreen], keeping all auth/API
/// logic out of the screen widget.
///
/// On a successful verify it calls [AuthNotifier.login], which persists the
/// session to secure storage and flips auth state — firing the router's
/// `refreshListenable` and redirecting out of the auth flow into the Projects
/// Hub. (The screen still navigates on `true`; the redirect is the safety net.)
///
/// TODO(auth): pass the real destination through from the auth screen instead of
/// hardcoding it; the network bodies in [AuthRepository] are still stubbed.
class OtpScreen extends ConsumerWidget {
  const OtpScreen({super.key});

  // The masked destination the code was sent to. See TODO above.
  static const String _destination = '+91 ••••• ••210';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OtpVerificationScreen(
      destination: _destination,
      onVerify: (code) async {
        final session = await ref.read(authRepositoryProvider).verifyOtp(
              destination: _destination,
              code: code,
            );
        if (session == null) return false; // invalid code
        // Persist + flip auth state. refreshListenable redirects off OTP.
        await ref.read(authProvider.notifier).login(session);
        return true;
      },
      onResend: () async {
        // TODO(auth): await ref.read(authRepositoryProvider).resendOtp(...);
      },
    );
  }
}
