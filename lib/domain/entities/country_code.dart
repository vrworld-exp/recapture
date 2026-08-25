// lib/domain/entities/country_code.dart
import 'package:flutter/foundation.dart';

/// A dialing-code entry for the auth phone input: ISO 3166-1 alpha-2 code,
/// display name, and the `+`-prefixed international dialing code.
///
/// The flag is DERIVED from [iso2] (regional-indicator emoji), so the list
/// below needs no image assets and can never show a flag that disagrees with
/// its country code.
@immutable
class CountryCode {
  const CountryCode({
    required this.iso2,
    required this.name,
    required this.dialCode,
  });

  /// Uppercase ISO 3166-1 alpha-2 code, e.g. `IN`.
  final String iso2;

  /// English display name, e.g. `India`.
  final String name;

  /// International dialing code with the `+` prefix, e.g. `+91`.
  final String dialCode;

  /// The country's flag as a two-character regional-indicator emoji (🇮🇳 for
  /// `IN`): each A–Z letter maps to U+1F1E6..U+1F1FF.
  String get flagEmoji => String.fromCharCodes(
        iso2.codeUnits.map((unit) => 0x1F1E6 + (unit - 0x41)),
      );

  /// Digits of [dialCode] (no `+`), for E.164 length accounting.
  String get dialDigits => dialCode.substring(1);

  @override
  bool operator ==(Object other) =>
      other is CountryCode && other.iso2 == iso2 && other.dialCode == dialCode;

  @override
  int get hashCode => Object.hash(iso2, dialCode);

  @override
  String toString() => 'CountryCode($iso2 $dialCode)';
}

/// The pre-selected country for the phone input: India (+91).
const CountryCode kDefaultCountryCode =
    CountryCode(iso2: 'IN', name: 'India', dialCode: '+91');

/// Countries offered by the dial-code picker, alphabetical by display name.
/// Curated (major countries and all of ReCapture's plausible markets) rather
/// than the exhaustive ISO registry — extend freely; the picker and the
/// validators only assume `iso2` is unique and `dialCode` starts with `+`.
const List<CountryCode> kCountryCodes = [
  CountryCode(iso2: 'AF', name: 'Afghanistan', dialCode: '+93'),
  CountryCode(iso2: 'AL', name: 'Albania', dialCode: '+355'),
  CountryCode(iso2: 'DZ', name: 'Algeria', dialCode: '+213'),
  CountryCode(iso2: 'AR', name: 'Argentina', dialCode: '+54'),
  CountryCode(iso2: 'AM', name: 'Armenia', dialCode: '+374'),
  CountryCode(iso2: 'AU', name: 'Australia', dialCode: '+61'),
  CountryCode(iso2: 'AT', name: 'Austria', dialCode: '+43'),
  CountryCode(iso2: 'AZ', name: 'Azerbaijan', dialCode: '+994'),
  CountryCode(iso2: 'BH', name: 'Bahrain', dialCode: '+973'),
  CountryCode(iso2: 'BD', name: 'Bangladesh', dialCode: '+880'),
  CountryCode(iso2: 'BY', name: 'Belarus', dialCode: '+375'),
  CountryCode(iso2: 'BE', name: 'Belgium', dialCode: '+32'),
  CountryCode(iso2: 'BT', name: 'Bhutan', dialCode: '+975'),
  CountryCode(iso2: 'BO', name: 'Bolivia', dialCode: '+591'),
  CountryCode(iso2: 'BA', name: 'Bosnia and Herzegovina', dialCode: '+387'),
  CountryCode(iso2: 'BW', name: 'Botswana', dialCode: '+267'),
  CountryCode(iso2: 'BR', name: 'Brazil', dialCode: '+55'),
  CountryCode(iso2: 'BG', name: 'Bulgaria', dialCode: '+359'),
  CountryCode(iso2: 'KH', name: 'Cambodia', dialCode: '+855'),
  CountryCode(iso2: 'CM', name: 'Cameroon', dialCode: '+237'),
  CountryCode(iso2: 'CA', name: 'Canada', dialCode: '+1'),
  CountryCode(iso2: 'CL', name: 'Chile', dialCode: '+56'),
  CountryCode(iso2: 'CN', name: 'China', dialCode: '+86'),
  CountryCode(iso2: 'CO', name: 'Colombia', dialCode: '+57'),
  CountryCode(iso2: 'CR', name: 'Costa Rica', dialCode: '+506'),
  CountryCode(iso2: 'HR', name: 'Croatia', dialCode: '+385'),
  CountryCode(iso2: 'CU', name: 'Cuba', dialCode: '+53'),
  CountryCode(iso2: 'CY', name: 'Cyprus', dialCode: '+357'),
  CountryCode(iso2: 'CZ', name: 'Czechia', dialCode: '+420'),
  CountryCode(iso2: 'DK', name: 'Denmark', dialCode: '+45'),
  CountryCode(iso2: 'DO', name: 'Dominican Republic', dialCode: '+1'),
  CountryCode(iso2: 'EC', name: 'Ecuador', dialCode: '+593'),
  CountryCode(iso2: 'EG', name: 'Egypt', dialCode: '+20'),
  CountryCode(iso2: 'SV', name: 'El Salvador', dialCode: '+503'),
  CountryCode(iso2: 'EE', name: 'Estonia', dialCode: '+372'),
  CountryCode(iso2: 'ET', name: 'Ethiopia', dialCode: '+251'),
  CountryCode(iso2: 'FJ', name: 'Fiji', dialCode: '+679'),
  CountryCode(iso2: 'FI', name: 'Finland', dialCode: '+358'),
  CountryCode(iso2: 'FR', name: 'France', dialCode: '+33'),
  CountryCode(iso2: 'GE', name: 'Georgia', dialCode: '+995'),
  CountryCode(iso2: 'DE', name: 'Germany', dialCode: '+49'),
  CountryCode(iso2: 'GH', name: 'Ghana', dialCode: '+233'),
  CountryCode(iso2: 'GR', name: 'Greece', dialCode: '+30'),
  CountryCode(iso2: 'GT', name: 'Guatemala', dialCode: '+502'),
  CountryCode(iso2: 'HN', name: 'Honduras', dialCode: '+504'),
  CountryCode(iso2: 'HK', name: 'Hong Kong', dialCode: '+852'),
  CountryCode(iso2: 'HU', name: 'Hungary', dialCode: '+36'),
  CountryCode(iso2: 'IS', name: 'Iceland', dialCode: '+354'),
  CountryCode(iso2: 'IN', name: 'India', dialCode: '+91'),
  CountryCode(iso2: 'ID', name: 'Indonesia', dialCode: '+62'),
  CountryCode(iso2: 'IR', name: 'Iran', dialCode: '+98'),
  CountryCode(iso2: 'IQ', name: 'Iraq', dialCode: '+964'),
  CountryCode(iso2: 'IE', name: 'Ireland', dialCode: '+353'),
  CountryCode(iso2: 'IL', name: 'Israel', dialCode: '+972'),
  CountryCode(iso2: 'IT', name: 'Italy', dialCode: '+39'),
  CountryCode(iso2: 'JM', name: 'Jamaica', dialCode: '+1'),
  CountryCode(iso2: 'JP', name: 'Japan', dialCode: '+81'),
  CountryCode(iso2: 'JO', name: 'Jordan', dialCode: '+962'),
  CountryCode(iso2: 'KZ', name: 'Kazakhstan', dialCode: '+7'),
  CountryCode(iso2: 'KE', name: 'Kenya', dialCode: '+254'),
  CountryCode(iso2: 'KW', name: 'Kuwait', dialCode: '+965'),
  CountryCode(iso2: 'KG', name: 'Kyrgyzstan', dialCode: '+996'),
  CountryCode(iso2: 'LA', name: 'Laos', dialCode: '+856'),
  CountryCode(iso2: 'LV', name: 'Latvia', dialCode: '+371'),
  CountryCode(iso2: 'LB', name: 'Lebanon', dialCode: '+961'),
  CountryCode(iso2: 'LY', name: 'Libya', dialCode: '+218'),
  CountryCode(iso2: 'LT', name: 'Lithuania', dialCode: '+370'),
  CountryCode(iso2: 'LU', name: 'Luxembourg', dialCode: '+352'),
  CountryCode(iso2: 'MO', name: 'Macao', dialCode: '+853'),
  CountryCode(iso2: 'MG', name: 'Madagascar', dialCode: '+261'),
  CountryCode(iso2: 'MW', name: 'Malawi', dialCode: '+265'),
  CountryCode(iso2: 'MY', name: 'Malaysia', dialCode: '+60'),
  CountryCode(iso2: 'MV', name: 'Maldives', dialCode: '+960'),
  CountryCode(iso2: 'MT', name: 'Malta', dialCode: '+356'),
  CountryCode(iso2: 'MU', name: 'Mauritius', dialCode: '+230'),
  CountryCode(iso2: 'MX', name: 'Mexico', dialCode: '+52'),
  CountryCode(iso2: 'MD', name: 'Moldova', dialCode: '+373'),
  CountryCode(iso2: 'MC', name: 'Monaco', dialCode: '+377'),
  CountryCode(iso2: 'MN', name: 'Mongolia', dialCode: '+976'),
  CountryCode(iso2: 'ME', name: 'Montenegro', dialCode: '+382'),
  CountryCode(iso2: 'MA', name: 'Morocco', dialCode: '+212'),
  CountryCode(iso2: 'MZ', name: 'Mozambique', dialCode: '+258'),
  CountryCode(iso2: 'MM', name: 'Myanmar', dialCode: '+95'),
  CountryCode(iso2: 'NA', name: 'Namibia', dialCode: '+264'),
  CountryCode(iso2: 'NP', name: 'Nepal', dialCode: '+977'),
  CountryCode(iso2: 'NL', name: 'Netherlands', dialCode: '+31'),
  CountryCode(iso2: 'NZ', name: 'New Zealand', dialCode: '+64'),
  CountryCode(iso2: 'NI', name: 'Nicaragua', dialCode: '+505'),
  CountryCode(iso2: 'NG', name: 'Nigeria', dialCode: '+234'),
  CountryCode(iso2: 'MK', name: 'North Macedonia', dialCode: '+389'),
  CountryCode(iso2: 'NO', name: 'Norway', dialCode: '+47'),
  CountryCode(iso2: 'OM', name: 'Oman', dialCode: '+968'),
  CountryCode(iso2: 'PK', name: 'Pakistan', dialCode: '+92'),
  CountryCode(iso2: 'PS', name: 'Palestine', dialCode: '+970'),
  CountryCode(iso2: 'PA', name: 'Panama', dialCode: '+507'),
  CountryCode(iso2: 'PG', name: 'Papua New Guinea', dialCode: '+675'),
  CountryCode(iso2: 'PY', name: 'Paraguay', dialCode: '+595'),
  CountryCode(iso2: 'PE', name: 'Peru', dialCode: '+51'),
  CountryCode(iso2: 'PH', name: 'Philippines', dialCode: '+63'),
  CountryCode(iso2: 'PL', name: 'Poland', dialCode: '+48'),
  CountryCode(iso2: 'PT', name: 'Portugal', dialCode: '+351'),
  CountryCode(iso2: 'PR', name: 'Puerto Rico', dialCode: '+1'),
  CountryCode(iso2: 'QA', name: 'Qatar', dialCode: '+974'),
  CountryCode(iso2: 'RO', name: 'Romania', dialCode: '+40'),
  CountryCode(iso2: 'RU', name: 'Russia', dialCode: '+7'),
  CountryCode(iso2: 'RW', name: 'Rwanda', dialCode: '+250'),
  CountryCode(iso2: 'SA', name: 'Saudi Arabia', dialCode: '+966'),
  CountryCode(iso2: 'SN', name: 'Senegal', dialCode: '+221'),
  CountryCode(iso2: 'RS', name: 'Serbia', dialCode: '+381'),
  CountryCode(iso2: 'SG', name: 'Singapore', dialCode: '+65'),
  CountryCode(iso2: 'SK', name: 'Slovakia', dialCode: '+421'),
  CountryCode(iso2: 'SI', name: 'Slovenia', dialCode: '+386'),
  CountryCode(iso2: 'SO', name: 'Somalia', dialCode: '+252'),
  CountryCode(iso2: 'ZA', name: 'South Africa', dialCode: '+27'),
  CountryCode(iso2: 'KR', name: 'South Korea', dialCode: '+82'),
  CountryCode(iso2: 'ES', name: 'Spain', dialCode: '+34'),
  CountryCode(iso2: 'LK', name: 'Sri Lanka', dialCode: '+94'),
  CountryCode(iso2: 'SD', name: 'Sudan', dialCode: '+249'),
  CountryCode(iso2: 'SE', name: 'Sweden', dialCode: '+46'),
  CountryCode(iso2: 'CH', name: 'Switzerland', dialCode: '+41'),
  CountryCode(iso2: 'SY', name: 'Syria', dialCode: '+963'),
  CountryCode(iso2: 'TW', name: 'Taiwan', dialCode: '+886'),
  CountryCode(iso2: 'TJ', name: 'Tajikistan', dialCode: '+992'),
  CountryCode(iso2: 'TZ', name: 'Tanzania', dialCode: '+255'),
  CountryCode(iso2: 'TH', name: 'Thailand', dialCode: '+66'),
  CountryCode(iso2: 'TN', name: 'Tunisia', dialCode: '+216'),
  CountryCode(iso2: 'TR', name: 'Türkiye', dialCode: '+90'),
  CountryCode(iso2: 'TM', name: 'Turkmenistan', dialCode: '+993'),
  CountryCode(iso2: 'UG', name: 'Uganda', dialCode: '+256'),
  CountryCode(iso2: 'UA', name: 'Ukraine', dialCode: '+380'),
  CountryCode(iso2: 'AE', name: 'United Arab Emirates', dialCode: '+971'),
  CountryCode(iso2: 'GB', name: 'United Kingdom', dialCode: '+44'),
  CountryCode(iso2: 'US', name: 'United States', dialCode: '+1'),
  CountryCode(iso2: 'UY', name: 'Uruguay', dialCode: '+598'),
  CountryCode(iso2: 'UZ', name: 'Uzbekistan', dialCode: '+998'),
  CountryCode(iso2: 'VE', name: 'Venezuela', dialCode: '+58'),
  CountryCode(iso2: 'VN', name: 'Vietnam', dialCode: '+84'),
  CountryCode(iso2: 'YE', name: 'Yemen', dialCode: '+967'),
  CountryCode(iso2: 'ZM', name: 'Zambia', dialCode: '+260'),
  CountryCode(iso2: 'ZW', name: 'Zimbabwe', dialCode: '+263'),
];
