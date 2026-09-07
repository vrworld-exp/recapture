// lib/domain/entities/qr_standee.dart
//
// The admin's view of pre-printed standee inventory: a mint run, and the codes
// in it.
//
// Hand-synced with `recapture-api/src/services/qrCodeService.ts` (QrBatchSummary,
// QrCodeRow), `src/services/standeeAssignmentService.ts` (AssignableRep,
// RepStandeeRow) and `src/models/types/qr.types.ts` (QR_CODE_STATES) — there is
// no shared package, per AGENTS.md §0.1.
import 'user_role.dart';

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

/// A staff member, as the assign picker and the admin row show them.
///
/// NAME OR MASK, NEVER A RAW NUMBER. The backend ships `contactMasked`
/// (`+91 ••••• ••210`) and no raw phone or email, matching `GET /auth/me`, so
/// [label] is the most identifying string this class can ever produce.
class StandeeAssignee {
  const StandeeAssignee({
    required this.id,
    this.displayName,
    this.contactMasked,
  });

  final String id;

  /// Optional — reps set one rarely, which is exactly why [contactMasked]
  /// exists.
  final String? displayName;

  final String? contactMasked;

  /// What a row prints for this person.
  ///
  /// Falls back through name → masked contact → a placeholder, so a picker can
  /// never render a blank line that an admin would have to guess at.
  String get label {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final masked = contactMasked?.trim();
    if (masked != null && masked.isNotEmpty) return masked;
    return 'Unnamed account';
  }

  /// The second line, shown only when it adds something [label] did not.
  String? get secondaryLabel {
    final name = displayName?.trim();
    if (name == null || name.isEmpty) return null;
    final masked = contactMasked?.trim();
    return (masked == null || masked.isEmpty) ? null : masked;
  }

  static StandeeAssignee fromMap(Map<String, dynamic> map) => StandeeAssignee(
        id: (map['id'] ?? '').toString(),
        displayName: _nonEmpty(map['displayName']),
        contactMasked: _nonEmpty(map['contactMasked']),
      );
}

/// One row of the admin's "hand this standee to…" picker.
///
/// Carries [role] on top of the assignee shape because the roster is defined by
/// CAPABILITY, not by an exact SALES_REP match — an admin or a model artist can
/// use `/rep` too, so both appear here and the label is what tells them apart.
class SalesRepSummary {
  const SalesRepSummary({required this.person, required this.role});

  final StandeeAssignee person;
  final UserRole role;

  String get id => person.id;

  static SalesRepSummary fromMap(Map<String, dynamic> map) => SalesRepSummary(
        person: StandeeAssignee.fromMap(map),
        role: UserRole.fromApiValue(map['role']?.toString()),
      );
}

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim();
  return (text == null || text.isEmpty) ? null : text;
}

/// One standee: the printed characters, what it encodes, and where it stands.
class QrStandeeCode {
  const QrStandeeCode({
    required this.code,
    required this.state,
    required this.url,
    this.activatedAt,
    this.assignedTo,
  });

  /// The 8 characters printed under the QR square.
  final String code;

  final QrCodeState state;

  /// Exactly what the QR encodes — composed server-side by the same function
  /// that writes the vendor CSV, so a row here and a line there are one object.
  final String url;

  final DateTime? activatedAt;

  /// The rep carrying this standee, or null for stock nobody holds.
  ///
  /// ADVISORY, not a reservation: an assigned code is still activatable by any
  /// rep. It says where the sheet went, which is what an admin opens this
  /// screen to find out.
  final StandeeAssignee? assignedTo;

  bool get isAssigned => assignedTo != null;

  static QrStandeeCode fromMap(Map<String, dynamic> map) {
    final holder = map['assignedTo'];
    return QrStandeeCode(
      code: (map['code'] ?? '').toString(),
      state: QrCodeState.fromApiValue(map['state']?.toString()),
      url: (map['url'] ?? '').toString(),
      activatedAt:
          DateTime.tryParse((map['activatedAt'] ?? '').toString())?.toLocal(),
      assignedTo: holder is Map<String, dynamic>
          ? StandeeAssignee.fromMap(holder)
          : null,
    );
  }

  QrStandeeCode copyWith({Object? assignedTo = _unset}) => QrStandeeCode(
        code: code,
        state: state,
        url: url,
        activatedAt: activatedAt,
        assignedTo: identical(assignedTo, _unset)
            ? this.assignedTo
            : assignedTo as StandeeAssignee?,
      );
}

const Object _unset = Object();

/// One standee on a rep's OWN list.
///
/// A separate type from [QrStandeeCode] rather than a nullable field bolted
/// onto it, because the two answer different questions and carry different
/// dates: the admin row asks "where did this code go" and shows when it was
/// activated; this one asks "what am I carrying" and shows when it was handed
/// over. Folding them together would give every screen two dates, one of which
/// is always null.
class RepStandee {
  const RepStandee({
    required this.code,
    required this.state,
    required this.url,
    this.assignedAt,
  });

  /// The 8 characters printed under the QR square.
  final String code;

  final QrCodeState state;

  /// Exactly what the QR encodes.
  final String url;

  /// When an admin handed it over.
  final DateTime? assignedAt;

  /// Whether tapping this row can start an activation.
  ///
  /// Reuses [QrCodeState.isAvailable] rather than re-deriving it, so "safe to
  /// put on a table" means the same thing on the rep's list as it does on the
  /// admin's — including the fail-closed treatment of an unrecognised state.
  bool get canActivate => state.isAvailable;

  /// Whether this row offers a printable sheet, matching the backend's refusal
  /// to render a retired standee.
  bool get isPrintable => state.isPrintable;

  static RepStandee fromMap(Map<String, dynamic> map) => RepStandee(
        code: (map['code'] ?? '').toString(),
        state: QrCodeState.fromApiValue(map['state']?.toString()),
        url: (map['url'] ?? '').toString(),
        assignedAt:
            DateTime.tryParse((map['assignedAt'] ?? '').toString())?.toLocal(),
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
