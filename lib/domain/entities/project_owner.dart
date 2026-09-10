// lib/domain/entities/project_owner.dart
//
// WHO captured a live project — the two shapes behind the ADMIN-only
// "Created by" label and the sheet it opens.
//
// TWO CLASSES, NOT ONE WITH NULLABLE CONTACT FIELDS, because they come from
// different places under different rules and the type is what keeps them apart:
//
//   • [ProjectOwnerSummary] rides on every row of `GET /admin/projects` when
//     the caller is ADMIN. A name and "do they have a picture" — no phone, no
//     email, not even a mask. Safe to hold a page of.
//   • [ProjectOwnerDetail] comes from `GET /admin/users/:id`, one person at a
//     time, and carries the RAW phone/email. It is the ONE unmasked contact
//     payload in this app (everywhere else — the Profile screen, the sales-rep
//     roster — shows a mask), which is why it is fetched only when an admin
//     actually opens someone, and never persisted, logged, or sent to
//     analytics. See recapture-api/src/services/adminUsersService.ts for the
//     server-side reasoning and its bounds.
//
// Neither shape carries an avatar URL. Pictures are read as BYTES through the
// API (`/admin/users/:id/avatar/bytes`) — the raw bucket serves no CORS, so a
// presigned URL renders on the apk and shows nothing at all on web, and one
// bytes path works for both builds.
import 'user_role.dart';

/// The list-safe owner shape: enough to label a project card.
class ProjectOwnerSummary {
  const ProjectOwnerSummary({
    required this.id,
    this.displayName,
    this.hasAvatar = false,
  });

  /// Opaque user id — the key for the detail call and the avatar fetch.
  final String id;

  /// The name the account chose, or null when it never set one (the OTP sign-up
  /// never asks for one, so this is common). Callers fall back to [initials]
  /// and then to [shortId].
  final String? displayName;

  /// Whether the account HAS a profile picture. A boolean rather than a URL, so
  /// a list can decide whether a row is worth one image request at all.
  final bool hasAvatar;

  bool get hasDisplayName => (displayName?.trim().isNotEmpty ?? false);

  /// What to write on the label when there is no name: the same truncated id
  /// the card showed before this feature existed.
  String get shortId => id.length <= 6 ? id : '…${id.substring(id.length - 6)}';

  /// The name if there is one, else the short id. Never empty.
  String get displayLabel => hasDisplayName ? displayName!.trim() : shortId;

  /// Up to two uppercase initials from [displayName], or null when there is no
  /// name to derive them from. Same rune-based rule as [UserProfile.initials] —
  /// a leading emoji yields one whole glyph, never half a surrogate pair.
  String? get initials {
    final name = displayName?.trim();
    if (name == null || name.isEmpty) return null;
    final words =
        name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    final first = String.fromCharCode(words.first.runes.first);
    if (words.length == 1) return first.toUpperCase();
    final last = String.fromCharCode(words.last.runes.first);
    return '$first$last'.toUpperCase();
  }

  /// Defensive parse of the `owner` object on a live-project row. Returns null
  /// for anything that is not a usable owner — the field is ABSENT for a
  /// non-ADMIN caller and for an account that no longer exists, and both must
  /// render as the plain opaque-id line rather than as a broken label.
  static ProjectOwnerSummary? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['displayName'];
    return ProjectOwnerSummary(
      id: id,
      displayName: name is String && name.trim().isNotEmpty ? name.trim() : null,
      hasAvatar: raw['hasAvatar'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectOwnerSummary &&
          other.id == id &&
          other.displayName == displayName &&
          other.hasAvatar == hasAvatar;

  @override
  int get hashCode => Object.hash(id, displayName, hasAvatar);
}

/// The full identity behind a project — what the admin sheet renders.
///
/// ⚠ [email] and [phone] are RAW. Render them; never log them, never persist
/// them, never put them in an analytics property. The provider that holds one
/// is autoDispose for exactly this reason: it lives as long as the sheet.
class ProjectOwnerDetail extends ProjectOwnerSummary {
  const ProjectOwnerDetail({
    required super.id,
    required this.role,
    required this.createdAt,
    super.displayName,
    super.hasAvatar,
    this.email,
    this.phone,
    this.emailVerified = false,
    this.phoneVerified = false,
  });

  /// RAW email, or null when the account has none.
  final String? email;

  /// RAW phone, or null when the account has none.
  final String? phone;

  final bool emailVerified;
  final bool phoneVerified;

  /// The owner's access role — an admin looking at a bad capture wants to know
  /// whether it came from a customer or from their own artist.
  final UserRole role;

  /// When the account was created, in UTC.
  final DateTime createdAt;

  /// True when there is at least one way to reach this person. When false the
  /// sheet says so plainly instead of rendering two empty rows.
  bool get hasAnyContact =>
      (email?.isNotEmpty ?? false) || (phone?.isNotEmpty ?? false);

  /// DEFENSIVE parse of the `user` object from `GET /admin/users/:id`. Every
  /// field beyond `id` is optional: an older backend must make the sheet render
  /// LESS, never crash it. A missing/ill-typed createdAt degrades to epoch —
  /// the "Member since" line is cosmetic and must not take the sheet down.
  static ProjectOwnerDetail? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;

    String? text(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;

    final createdAtRaw = raw['createdAt'];
    return ProjectOwnerDetail(
      id: id,
      displayName: text(raw['displayName']),
      hasAvatar: raw['hasAvatar'] == true,
      email: text(raw['email']),
      phone: text(raw['phone']),
      emailVerified: raw['emailVerified'] == true,
      phoneVerified: raw['phoneVerified'] == true,
      role: UserRole.fromApiValue(
        raw['role'] is String ? raw['role'] as String : null,
      ),
      createdAt:
          (createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null)
                  ?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}
