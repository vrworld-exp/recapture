// lib/domain/entities/qr_code_preflight.dart
import 'catalog_json.dart';

/// What `GET /rep/codes/:code` says about one standee, before the rep types a
/// restaurant's whole profile against it.
///
/// ADVISORY, NOT A DECISION. The state can change between this answer and the
/// activation, and the server's conditional claim is what actually arbitrates.
/// This exists so a rep sees "already in use" while looking at the code entry
/// box rather than after filling in a form — it saves typing, it does not
/// replace a guard.
class QrCodePreflight {
  const QrCodePreflight({
    required this.code,
    required this.state,
    required this.isAvailable,
  });

  /// The NORMALISED code, as the server stores it. Echoed back so the screen
  /// can show the rep what it actually read off their input.
  final String code;

  /// The raw lifecycle value (`UNASSIGNED` / `ACTIVE` / `RETIRED`). Kept as a
  /// string rather than an enum: nothing branches on it beyond
  /// [isAvailable], and an enum here would be a second vocabulary to keep in
  /// step for no gain.
  final String state;

  /// The only thing the screen acts on.
  final bool isAvailable;

  factory QrCodePreflight.fromMap(Map<String, dynamic> map) => QrCodePreflight(
        code: catalogText(map['code']) ?? '',
        state: catalogText(map['state']) ?? 'UNKNOWN',
        isAvailable: map['available'] == true,
      );
}
