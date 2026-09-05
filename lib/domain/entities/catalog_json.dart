// lib/domain/entities/catalog_json.dart
//
// Parsing helpers shared by the catalog entities.
//
// The catalog DTOs are hand-synced with the backend's TypeScript DTOs — there is
// no shared package and no code generation, so drift is caught by golden-JSON
// tests rather than by the compiler (AGENTS.md guardrails). Every entity here
// therefore parses FIELD BY FIELD and falls back to a safe value instead of
// throwing: a client one deploy behind must render the catalog, not crash on it.
//
// One set of helpers, not four private copies — a second `_parseDate` is how two
// entities end up disagreeing about what a missing timestamp means.

/// Trims and normalises an API string field. Null, non-string and empty all
/// collapse to null, so callers have one "nothing here" case instead of three.
String? catalogText(dynamic raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Parses an ISO-8601 timestamp (or epoch millis).
///
/// Returns null — never `DateTime.now()` — for a missing or malformed value. On
/// the catalog surface a fabricated timestamp would read as "published just
/// now", which is the one thing it must not claim.
DateTime? catalogDate(dynamic raw) {
  if (raw is String) return DateTime.tryParse(raw);
  if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
  return null;
}

/// A non-negative count, defaulting to 0 for anything unusable.
int catalogCount(dynamic raw) => raw is num && raw >= 0 ? raw.toInt() : 0;

/// A price. Null (not 0) when absent — "no price set" and "free" are different
/// things to a customer, and 0 would silently turn one into the other.
double? catalogPrice(dynamic raw) => raw is num ? raw.toDouble() : null;

/// A list of strings, tolerating a null or non-list value.
List<String> catalogStringList(dynamic raw) =>
    raw is List ? [for (final item in raw) item.toString()] : const <String>[];
