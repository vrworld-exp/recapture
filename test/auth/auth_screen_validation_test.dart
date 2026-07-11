// test/auth/auth_screen_validation_test.dart
//
// Widget contract for the auth screen's identifier validation and the
// two-part phone input: the dial-code button defaults to 🇮🇳 +91, invalid
// input shows an inline error and NEVER navigates to the OTP step, editing
// clears the error, the country sheet swaps the dial code (and its rules),
// and valid input proceeds to the OTP route.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/data/repositories/auth_repository.dart';
import 'package:recapture/platform/connectivity_watcher.dart';
import 'package:recapture/presentation/screens/auth/auth_screen.dart';

/// Always-online gate so Send OTP reaches navigation without the real plugin.
class _FakeConnectivity extends ConnectivityWatcher {
  @override
  Future<AppConnectivityStatus> currentStatus() async =>
      AppConnectivityStatus.online;
}

/// Network-free repository: send-otp always succeeds (no devCode), so valid
/// input proceeds to the OTP route without Dio/dotenv.
class _FakeAuthRepository extends AuthRepository {
  int sendCalls = 0;

  @override
  Future<OtpSendResult> sendOtp({
    required String channel,
    required String identifier,
  }) async {
    sendCalls++;
    return const OtpSendResult();
  }
}

const _otpMarker = 'OTP SCREEN STUB';

Future<void> _pumpAuth(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: AppRoutes.auth,
    routes: [
      GoRoute(
        path: AppRoutes.auth,
        name: AppRouteNames.auth,
        builder: (_, __) => AuthScreen(connectivity: _FakeConnectivity()),
      ),
      GoRoute(
        path: AppRoutes.otpVerify,
        name: AppRouteNames.otpVerify,
        builder: (_, __) => const Scaffold(body: Text(_otpMarker)),
      ),
    ],
  );
  // Pump under the REAL app theme: layout bugs can be theme-induced (e.g. the
  // theme's full-width OutlinedButton minimumSize inside an unbounded Row).
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
      ],
      child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapSendOtp(WidgetTester tester) async {
  await tester.tap(find.text('Send OTP'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('phone tab defaults to the Indian dial code with flag',
      (tester) async {
    await _pumpAuth(tester);
    expect(find.byKey(const ValueKey('country_code_button')), findsOneWidget);
    expect(find.text('+91'), findsOneWidget);
    expect(find.text('🇮🇳'), findsOneWidget);
  });

  testWidgets('empty phone shows an inline error and does not navigate',
      (tester) async {
    await _pumpAuth(tester);
    await _tapSendOtp(tester);
    expect(find.text('Enter your phone number.'), findsOneWidget);
    expect(find.text(_otpMarker), findsNothing);
  });

  testWidgets('a short Indian number is rejected with the 10-digit rule',
      (tester) async {
    await _pumpAuth(tester);
    await tester.enterText(
        find.byKey(const ValueKey('auth_phone_field')), '98765');
    await _tapSendOtp(tester);
    expect(find.text('Indian mobile numbers have 10 digits.'), findsOneWidget);
    expect(find.text(_otpMarker), findsNothing);
  });

  testWidgets('an Indian number starting below 6 is rejected', (tester) async {
    await _pumpAuth(tester);
    await tester.enterText(
        find.byKey(const ValueKey('auth_phone_field')), '1234567890');
    await _tapSendOtp(tester);
    expect(find.text('Indian mobile numbers start with 6, 7, 8 or 9.'),
        findsOneWidget);
    expect(find.text(_otpMarker), findsNothing);
  });

  testWidgets('editing the phone clears its inline error', (tester) async {
    await _pumpAuth(tester);
    await _tapSendOtp(tester);
    expect(find.text('Enter your phone number.'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('auth_phone_field')), '9');
    await tester.pump();
    expect(find.text('Enter your phone number.'), findsNothing);
  });

  testWidgets('a valid Indian mobile number proceeds to the OTP step',
      (tester) async {
    await _pumpAuth(tester);
    await tester.enterText(
        find.byKey(const ValueKey('auth_phone_field')), '9876543210');
    await _tapSendOtp(tester);
    expect(find.text(_otpMarker), findsOneWidget);
  });

  testWidgets(
      'country sheet: searching and picking the US swaps the dial code '
      'and its validation rule', (tester) async {
    await _pumpAuth(tester);
    await tester.tap(find.byKey(const ValueKey('country_code_button')));
    await tester.pumpAndSettle();

    // Search narrows the list; pick the United States.
    await tester.enterText(
        find.byKey(const ValueKey('country_search_field')), 'United States');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('country_tile_US')));
    await tester.pumpAndSettle();

    expect(find.text('+1'), findsOneWidget);
    expect(find.text('🇺🇸'), findsOneWidget);

    // The Indian 10-digit rule no longer applies — the generic envelope does.
    await tester.enterText(
        find.byKey(const ValueKey('auth_phone_field')), '123');
    await _tapSendOtp(tester);
    expect(find.text('Enter a valid phone number.'), findsOneWidget);
    expect(find.text(_otpMarker), findsNothing);
  });

  testWidgets('country sheet finds a country by dial code digits',
      (tester) async {
    await _pumpAuth(tester);
    await tester.tap(find.byKey(const ValueKey('country_code_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('country_search_field')), '+44');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('country_tile_GB')), findsOneWidget);
    expect(find.byKey(const ValueKey('country_tile_US')), findsNothing);
  });

  testWidgets('email tab: malformed address shows an inline error and stays',
      (tester) async {
    await _pumpAuth(tester);
    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('auth_email_field')), 'not-an-email');
    await _tapSendOtp(tester);
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text(_otpMarker), findsNothing);
  });

  testWidgets('email tab: a valid address proceeds to the OTP step',
      (tester) async {
    await _pumpAuth(tester);
    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('auth_email_field')), 'user@example.com');
    await _tapSendOtp(tester);
    expect(find.text(_otpMarker), findsOneWidget);
  });
}
