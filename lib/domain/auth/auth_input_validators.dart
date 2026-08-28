// lib/domain/auth/auth_input_validators.dart
import '../entities/country_code.dart';

/// Pure validators for the auth (login/sign-up) identifier inputs.
///
/// Each returns `null` when the input is acceptable, or a user-facing error
/// message ready for `AppTextField.errorText`. Kept free of Flutter imports so
/// the rules are unit-testable and reusable by any future form.
abstract final class AuthInputValidators {
  /// Pragmatic RFC-5322 subset: dot-atom local part (no leading/trailing/
  /// consecutive dots or specials), at least one domain dot, alphabetic TLD of
  /// 2+ chars, no hyphen at a domain-label edge.
  static final RegExp _emailPattern = RegExp(
    r'^[A-Za-z0-9]+([._%+-][A-Za-z0-9]+)*'
    r'@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$',
  );

  static final RegExp _digitsOnly = RegExp(r'^[0-9]+$');

  /// Validates a login/sign-up email. Leading/trailing whitespace is treated
  /// as a typo to forgive (trim before use), everything else must match
  /// [_emailPattern]; total length is capped at the SMTP path limit (254).
  static String? email(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return 'Enter your email address.';
    if (value.length > 254 || !_emailPattern.hasMatch(value)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  /// Validates the NATIONAL part of a phone number (the digits typed after the
  /// selected [country]'s dial code — never a `+` or the code itself).
  ///
  /// Spaces and dashes are forgiven (stripped) so a pasted "98765 43210"
  /// passes. India (+91) gets the strict mobile rule: exactly 10 digits,
  /// first digit 6–9, no leading 0 / retyped country code. Other countries
  /// get the E.164 envelope: 4–14 digits and dial code + number ≤ 15 digits.
  static String? phone(String raw, {required CountryCode country}) {
    final value = raw.replaceAll(RegExp(r'[\s-]'), '');
    if (value.isEmpty) return 'Enter your phone number.';
    if (value.startsWith('+')) {
      return 'Country code is already selected — enter just the number.';
    }
    if (!_digitsOnly.hasMatch(value)) return 'Use digits only.';

    if (country.dialCode == '+91') {
      if (value.startsWith('0')) {
        return 'Drop the leading 0 — enter the 10-digit mobile number.';
      }
      if (value.length != 10) return 'Indian mobile numbers have 10 digits.';
      if (!'6789'.contains(value[0])) {
        return 'Indian mobile numbers start with 6, 7, 8 or 9.';
      }
      return null;
    }

    final totalDigits = country.dialDigits.length + value.length;
    if (value.length < 4 || totalDigits > 15) {
      return 'Enter a valid phone number.';
    }
    return null;
  }
}
