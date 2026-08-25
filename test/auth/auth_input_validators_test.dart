// test/auth/auth_input_validators_test.dart
//
// Pure edge-case coverage for the login/sign-up identifier validators and the
// dial-code registry: email shape rules, the strict Indian mobile rule, the
// generic E.164 envelope for other countries, and the country-list invariants
// the picker/validators rely on (unique ISO codes, `+`-prefixed dial codes,
// derived flag emoji).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/auth/auth_input_validators.dart';
import 'package:recapture/domain/entities/country_code.dart';

const _us = CountryCode(iso2: 'US', name: 'United States', dialCode: '+1');
const _de = CountryCode(iso2: 'DE', name: 'Germany', dialCode: '+49');

void main() {
  group('AuthInputValidators.email', () {
    test('accepts common valid shapes', () {
      const valid = [
        'a@b.co',
        'user@example.com',
        'USER@EXAMPLE.COM',
        'user.name@example.com',
        'user+tag@example.co.in',
        'user_name@example.com',
        'u123@sub.domain.example.org',
      ];
      for (final email in valid) {
        expect(AuthInputValidators.email(email), isNull, reason: email);
      }
    });

    test('forgives leading/trailing whitespace (treated as a typo)', () {
      expect(AuthInputValidators.email('  user@example.com  '), isNull);
    });

    test('empty input gets the dedicated prompt', () {
      expect(AuthInputValidators.email(''), 'Enter your email address.');
      expect(AuthInputValidators.email('   '), 'Enter your email address.');
    });

    test('rejects malformed addresses', () {
      const invalid = [
        'plainaddress', // no @
        'user@nodot', // no TLD
        'user@example.', // trailing dot, empty TLD
        '.user@example.com', // leading dot in local part
        'user.@example.com', // trailing dot in local part
        'us..er@example.com', // consecutive dots in local part
        'user@exa mple.com', // space in domain
        'us er@example.com', // space in local part
        'user@@example.com', // double @
        'user@example..com', // consecutive dots in domain
        'user@-example.com', // hyphen at label start
        'user@example-.com', // hyphen at label end
        'user@example.c', // 1-char TLD
        'user@example.c0m', // digit in TLD
        '@example.com', // missing local part
        'user@', // missing domain
      ];
      for (final email in invalid) {
        expect(AuthInputValidators.email(email), 'Enter a valid email address.',
            reason: email);
      }
    });

    test('rejects addresses beyond the 254-char SMTP limit', () {
      final local = 'a' * 250;
      expect(AuthInputValidators.email('$local@example.com'),
          'Enter a valid email address.');
    });
  });

  group('AuthInputValidators.phone — India (+91)', () {
    String? phone(String raw) =>
        AuthInputValidators.phone(raw, country: kDefaultCountryCode);

    test('accepts a 10-digit mobile starting 6–9', () {
      expect(phone('9876543210'), isNull);
      expect(phone('6000000000'), isNull);
      expect(phone('7123456789'), isNull);
      expect(phone('8123456789'), isNull);
    });

    test('forgives spaces and dashes (paste formats)', () {
      expect(phone('98765 43210'), isNull);
      expect(phone('98765-43210'), isNull);
    });

    test('empty input gets the dedicated prompt', () {
      expect(phone(''), 'Enter your phone number.');
      expect(phone('   '), 'Enter your phone number.');
    });

    test('rejects a pasted +country-code form', () {
      expect(phone('+919876543210'),
          'Country code is already selected — enter just the number.');
    });

    test('rejects non-digits', () {
      expect(phone('98765abcde'), 'Use digits only.');
    });

    test('rejects a leading 0 with a targeted hint', () {
      expect(phone('0987654321'),
          'Drop the leading 0 — enter the 10-digit mobile number.');
    });

    test('rejects wrong lengths', () {
      expect(phone('98765'), 'Indian mobile numbers have 10 digits.');
      expect(phone('98765432101'), 'Indian mobile numbers have 10 digits.');
    });

    test('rejects a first digit outside 6–9', () {
      expect(phone('5876543210'),
          'Indian mobile numbers start with 6, 7, 8 or 9.');
      expect(phone('1234567890'),
          'Indian mobile numbers start with 6, 7, 8 or 9.');
    });
  });

  group('AuthInputValidators.phone — other countries (E.164 envelope)', () {
    test('accepts a plausible US number', () {
      expect(AuthInputValidators.phone('2345678901', country: _us), isNull);
    });

    test('rejects numbers shorter than 4 digits', () {
      expect(AuthInputValidators.phone('123', country: _us),
          'Enter a valid phone number.');
    });

    test('caps dial code + number at 15 total digits', () {
      // +49 (2 digits) + 13 = 15 → OK; + 14 = 16 → too long.
      expect(AuthInputValidators.phone('1' * 13, country: _de), isNull);
      expect(AuthInputValidators.phone('1' * 14, country: _de),
          'Enter a valid phone number.');
    });
  });

  group('country code registry', () {
    test('default is India +91 and it exists in the list', () {
      expect(kDefaultCountryCode.iso2, 'IN');
      expect(kDefaultCountryCode.dialCode, '+91');
      expect(kCountryCodes.contains(kDefaultCountryCode), isTrue);
    });

    test('flag emoji is derived from the ISO code', () {
      expect(kDefaultCountryCode.flagEmoji, '🇮🇳');
      expect(_us.flagEmoji, '🇺🇸');
    });

    test('every entry has a well-formed ISO code and dial code', () {
      final iso = RegExp(r'^[A-Z]{2}$');
      final dial = RegExp(r'^\+\d{1,4}$');
      for (final c in kCountryCodes) {
        expect(iso.hasMatch(c.iso2), isTrue, reason: c.toString());
        expect(dial.hasMatch(c.dialCode), isTrue, reason: c.toString());
        expect(c.name, isNotEmpty, reason: c.toString());
      }
    });

    test('ISO codes are unique (dial codes may repeat, e.g. +1)', () {
      final seen = kCountryCodes.map((c) => c.iso2).toSet();
      expect(seen.length, kCountryCodes.length);
    });
  });
}
