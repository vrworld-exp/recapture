// test/auth/otp_dev_code_chip_test.dart
//
// The DEV-ONLY autofill chip on the OTP screen: renders only when a devCode is
// present (development backend echo), carries the unmissable label, and a tap
// fills the boxes and triggers exactly one verify with that code. Tests run
// with the default dev flavor, so the !kAppEnvironment.isProduction gate is
// open here; the prod-flavor gate itself is a compile-time constant (not
// testable in flutter test).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/presentation/screens/auth/otp_verification_screen.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? devCode,
  required Future<bool> Function(String code) onVerify,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: OtpVerificationScreen(
        destination: '+91 ••••• ••210',
        devCode: devCode,
        onVerify: onVerify,
        onResend: () async {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('no devCode → no chip (the production shape)', (tester) async {
    await _pump(tester, onVerify: (_) async => true);
    expect(find.byKey(const Key('dev_otp_chip')), findsNothing);
    expect(find.text('FOR DEV ONLY'), findsNothing);
  });

  testWidgets('devCode present → labelled chip with the code', (tester) async {
    await _pump(tester, devCode: '123456', onVerify: (_) async => true);
    expect(find.byKey(const Key('dev_otp_chip')), findsOneWidget);
    expect(find.text('FOR DEV ONLY'), findsOneWidget);
    expect(find.text('OTP: 123456'), findsOneWidget);
    expect(find.text('Tap to fill'), findsOneWidget);
  });

  testWidgets('tap fills the boxes and verifies once with the dev code',
      (tester) async {
    final codes = <String>[];
    await _pump(tester, devCode: '123456', onVerify: (code) async {
      codes.add(code);
      return false; // invalid → stays on screen (no router needed)
    });

    await tester.tap(find.byKey(const Key('dev_otp_chip')));
    await tester.pumpAndSettle();

    expect(codes, ['123456']);
    // The false outcome surfaces the normal invalid-code error state.
    expect(find.text('Incorrect code, try again'), findsOneWidget);
  });
}
