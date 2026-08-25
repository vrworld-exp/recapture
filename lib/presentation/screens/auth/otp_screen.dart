// lib/presentation/screens/auth/otp_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../application/auth/auth_notifier.dart';
import '../../../application/auth/otp_request.dart';
import '../../../data/repositories/auth_repository.dart';
import 'otp_verification_screen.dart';

/// Route host for the OTP flow. Reads the dispatched request (destination,
/// channel, dev echo) from [otpRequestProvider] and supplies the REAL
/// verify/resend callbacks to [OtpVerificationScreen], keeping all auth/API
/// logic out of the screen widget.
///
/// On a successful verify it calls [AuthNotifier.login], which persists the
/// session to secure storage and flips auth state — firing the router's
/// `refreshListenable` and redirecting out of the auth flow into the Projects
/// Hub. (The screen still navigates on `true`; the redirect is the safety net.)
class OtpScreen extends ConsumerWidget {
  const OtpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(otpRequestProvider);

    // No dispatched request (deep link / restored stack) — nothing to verify
    // against; bounce back to the auth screen to (re)send a code.
    if (request == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.goNamed(AppRouteNames.auth);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    return OtpVerificationScreen(
      destination: request.maskedDestination,
      // DEV-ONLY autofill: present only when the backend echoed the code
      // (NODE_ENV=development). Null in production → no chip.
      devCode: request.devCode,
      onVerify: (code) async {
        final session = await ref.read(authRepositoryProvider).verifyOtp(
              channel: request.channel,
              identifier: request.identifier,
              code: code,
            );
        if (session == null) return false; // invalid code
        // Persist + flip auth state. refreshListenable redirects off OTP.
        await ref.read(authProvider.notifier).login(session);
        ref.read(otpRequestProvider.notifier).clear();
        return true;
      },
      onResend: () async {
        final result = await ref.read(authRepositoryProvider).sendOtp(
              channel: request.channel,
              identifier: request.identifier,
            );
        // A resend mints a NEW code — refresh (or clear) the dev echo so the
        // chip never offers a stale code.
        ref.read(otpRequestProvider.notifier).updateDevCode(result.devCode);
      },
    );
  }
}
