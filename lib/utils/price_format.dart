// lib/utils/price_format.dart
//
// Price display for the catalog surface.
//
// Hand-rolled rather than `intl`-backed on purpose: the app does not depend on
// `intl` today, and the catalog brief forbids a new package for this. What is
// needed is narrow and stable — one amount, one ISO currency code, no plurals,
// no dates, no locale negotiation — so the whole job is a symbol lookup and a
// grouping rule.
//
// The grouping rule is not cosmetic. India groups the digits above a thousand in
// pairs (₹12,34,567), and this app's default currency is INR, so Western
// grouping would render every price above ₹99,999 in a shape its own users read
// as wrong.

/// Symbols for the currencies this product is likely to meet. Anything else
/// falls back to its ISO code, which is always correct if less pretty.
const Map<String, String> _currencySymbols = {
  'INR': '₹',
  'USD': r'$',
  'EUR': '€',
  'GBP': '£',
  'AED': 'AED ',
  'AUD': r'A$',
  'CAD': r'C$',
  'JPY': '¥',
  'SGD': r'S$',
};

/// Formats [amount] in [currency] for display.
///
/// Returns null when there is no price — NOT "0" and not "Free". A product with
/// no price set and a product that costs nothing are different claims, and the
/// caller decides which sentence to show ("No price set").
String? formatPrice(double? amount, String currency) {
  if (amount == null) return null;

  final code = currency.trim().toUpperCase();
  final symbol = _currencySymbols[code] ?? '$code ';

  final negative = amount < 0;
  final value = amount.abs();

  // Two decimals only when they carry information. A menu of round prices
  // should not read as an invoice.
  final hasFraction = (value * 100).round() % 100 != 0;
  final fixed = value.toStringAsFixed(hasFraction ? 2 : 0);
  final parts = fixed.split('.');

  final grouped = code == 'INR'
      ? _groupIndian(parts.first)
      : _groupWestern(parts.first);

  final body = parts.length > 1 ? '$grouped.${parts[1]}' : grouped;
  return '${negative ? '-' : ''}$symbol$body';
}

/// 1234567 → 1,234,567
String _groupWestern(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// 1234567 → 12,34,567 (the last three digits, then pairs).
String _groupIndian(String digits) {
  if (digits.length <= 3) return digits;
  final head = digits.substring(0, digits.length - 3);
  final tail = digits.substring(digits.length - 3);

  final buffer = StringBuffer();
  for (var i = 0; i < head.length; i++) {
    if (i > 0 && (head.length - i) % 2 == 0) buffer.write(',');
    buffer.write(head[i]);
  }
  return '$buffer,$tail';
}

/// Abbreviates a count for a tile that has no room for the exact number
/// (1234 → "1.2k"). The exact value belongs in the tooltip next to it — this
/// rounds, and a rounded number presented as the only truth is a lie the
/// analytics dashboard cannot afford.
String abbreviateCount(int value) {
  final negative = value < 0;
  final n = value.abs();
  final text = switch (n) {
    < 1000 => '$n',
    < 1000000 => '${_trimZero((n / 1000).toStringAsFixed(1))}k',
    < 1000000000 => '${_trimZero((n / 1000000).toStringAsFixed(1))}M',
    _ => '${_trimZero((n / 1000000000).toStringAsFixed(1))}B',
  };
  return negative ? '-$text' : text;
}

/// Formats a whole count with thousands separators (1234 → "1,234").
String formatCount(int value) =>
    value < 0 ? '-${_groupWestern('${-value}')}' : _groupWestern('$value');

String _trimZero(String value) =>
    value.endsWith('.0') ? value.substring(0, value.length - 2) : value;
