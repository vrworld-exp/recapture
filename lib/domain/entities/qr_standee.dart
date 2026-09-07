// lib/domain/entities/qr_standee.dart
//
// The admin's view of pre-printed standee inventory: a mint run, and the codes
// in it.
//
// Hand-synced with `recapture-api/src/services/qrCodeService.ts` (QrBatchSummary,
// QrCodeRow) and `src/models/types/qr.types.ts` (QR_CODE_STATES) — there is no
// shared package, per AGENTS.md §0.1.

/// Lifecycle of one physical standee, mirroring the backend's `QR_CODE_STATES`.
enum QrCodeState {
  /// Minted, probably printed, pointing at nothing. This is stock in a box.
  unassigned,

  /// Carries a catalog and resolves to that restaurant's menu.
  active,

  /// Deliberately taken out of service. Never reprint one — mint a replacement.
  retired,

  /// A state this build does not know about.
  ///
  /// NOT folded into [unassigned], which is the tempting default and the wrong
  /// one: "unassigned" is the screen's word for AVAILABLE, so an unrecognised
  /// state read as available is how an admin hands out a code that is already
  /// taken and the rep discovers it at the table. Rolling the backend ahead of
  /// the client must cost a row that reads "Unknown", not a bad standee.
  unknown;

  static QrCodeState fromApiValue(String? value) => switch (value) {
        'UNASSIGNED' => QrCodeState.unassigned,
        'ACTIVE' => QrCodeState.active,
        'RETIRED' => QrCodeState.retired,
        _ => QrCodeState.unknown,
      };

  /// What the row says. Sentence case, matching the rest of the app.
  String get label => switch (this) {
        QrCodeState.unassigned => 'Available',
        QrCodeState.active => 'In use',
        QrCodeState.retired => 'Retired',
        QrCodeState.unknown => 'Unknown',
      };

  /// Whether a standee in this state is safe to hand to a rep.
  ///
  /// Only [unassigned] is. An ACTIVE code belongs to a restaurant already, and
  /// both RETIRED and [unknown] fail closed.
  bool get isAvailable => this == QrCodeState.unassigned;

  /// Whether rendering this code as a printable QR is allowed.
  ///
  /// Mirrors the backend's 409 `CODE_RETIRED`: an ACTIVE code may legitimately
  /// be reprinted (a damaged standee for a live restaurant keeps its code — that
  /// is the whole point of the resolver), a retired one never may.
  bool get isPrintable =>
      this == QrCodeState.unassigned || this == QrCodeState.active;
}

/// One mint run, with a live breakdown of what is left in it.
class QrBatchSummary {
  const QrBatchSummary({
    required this.id,
    required this.label,
    required this.count,
    required this.createdAt,
    required this.unassigned,
    required this.active,
    required this.retired,
  });

  final String id;

  /// Free text from whoever minted it, e.g. "Vendor A — Oct 2026, run 3".
  final String label;

  /// Codes REQUESTED at mint, and therefore the export CSV's expected row count.
  ///
  /// Shown BESIDE the state totals rather than reconciled against them. The
  /// backend rolls a short mint back rather than leaving one behind, so the two
  /// agreeing is an invariant — and a screen that hid a disagreement would throw
  /// away the only place anyone would notice it broke.
  final int count;

  final DateTime createdAt;
  final int unassigned;
  final int active;
  final int retired;

  /// Codes accounted for across every known state.
  int get known => unassigned + active + retired;

  static QrBatchSummary fromMap(Map<String, dynamic> map) => QrBatchSummary(
        id: (map['id'] ?? '').toString(),
        label: (map['label'] ?? '').toString(),
        count: (map['count'] as num?)?.toInt() ?? 0,
        createdAt:
            DateTime.tryParse((map['createdAt'] ?? '').toString())?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
        unassigned: (map['unassigned'] as num?)?.toInt() ?? 0,
        active: (map['active'] as num?)?.toInt() ?? 0,
        retired: (map['retired'] as num?)?.toInt() ?? 0,
      );
}

/// One standee: the printed characters, what it encodes, and where it stands.
class QrStandeeCode {
  const QrStandeeCode({
    required this.code,
    required this.state,
    required this.url,
    this.activatedAt,
  });

  /// The 8 characters printed under the QR square.
  final String code;

  final QrCodeState state;

  /// Exactly what the QR encodes — composed server-side by the same function
  /// that writes the vendor CSV, so a row here and a line there are one object.
  final String url;

  final DateTime? activatedAt;

  static QrStandeeCode fromMap(Map<String, dynamic> map) => QrStandeeCode(
        code: (map['code'] ?? '').toString(),
        state: QrCodeState.fromApiValue(map['state']?.toString()),
        url: (map['url'] ?? '').toString(),
        activatedAt:
            DateTime.tryParse((map['activatedAt'] ?? '').toString())?.toLocal(),
      );
}

/// One keyset page of a batch's codes.
class QrCodePage {
  const QrCodePage({required this.codes, this.nextAfter});

  final List<QrStandeeCode> codes;

  /// Cursor for the next page, or null at the end of the batch.
  final String? nextAfter;
}

/// What a mint produced.
class QrMintResult {
  const QrMintResult({required this.batchId, required this.minted});

  final String batchId;
  final int minted;
}
