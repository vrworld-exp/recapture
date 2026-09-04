// lib/domain/rep/qr_code_input.dart

/// Turning whatever a rep put in the box into the code the server stores.
///
/// A CONVENIENCE, NEVER A TRUST BOUNDARY. The server normalises again with its
/// own `normalizeQrCode` and only its answer decides anything; this copy exists
/// so the keyboard behaves — a code printed `ABCD-2345` types cleanly, a
/// lowercase scan matches, and a pasted standee URL resolves instead of
/// failing validation in front of a restaurant owner.
///
/// Kept free of Flutter imports so the rules are unit-testable on their own.
abstract final class QrCodeInput {
  /// The stored form's length, mirroring the backend's `QR_CODE_LENGTH`.
  static const int length = 8;

  /// Crockford base32 with I, L, O and U removed — the backend's alphabet
  /// exactly. I/L collide with 1 and O with 0 when read off a printed sticker,
  /// which is why they are not in it, and why this must not "helpfully" map
  /// them: two different printed codes would normalise to the same stored one.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static final RegExp _stored = RegExp('^[$alphabet]{$length}\$');
  static final RegExp _separators = RegExp(r'[\s\-]');

  /// The stored form of [raw], or null when it could never be a code.
  ///
  /// Accepts, in order: a bare code in any case, a hyphenated or spaced code,
  /// and a full resolver URL. Returning null for anything else is what keeps a
  /// hopeless request off the network — the same reasoning as the server's
  /// normaliser refusing to query for a code that cannot exist.
  static String? normalize(String raw) {
    final candidate = _lastPathSegment(raw.trim());
    final stripped = candidate.replaceAll(_separators, '').toUpperCase();
    return _stored.hasMatch(stripped) ? stripped : null;
  }

  /// Whether [raw] would resolve to a code.
  static bool isValid(String raw) => normalize(raw) != null;

  /// The trailing segment of a pasted standee URL, or [value] unchanged.
  ///
  /// A rep WILL paste `https://scan.example/r/ABCD2345` at some point — it is
  /// what a phone offers after scanning with the OS camera — and refusing it
  /// would be the app rejecting its own printed output. Query and fragment are
  /// dropped first so `…/r/ABCD2345?utm=x` still works.
  static String _lastPathSegment(String value) {
    if (!value.contains('/')) return value;
    final withoutQuery = value.split(RegExp(r'[?#]')).first;
    final segments =
        withoutQuery.split('/').where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? value : segments.last;
  }
}
