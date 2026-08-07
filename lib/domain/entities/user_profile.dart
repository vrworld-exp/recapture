// lib/domain/entities/user_profile.dart
//
// The signed-in user's own account snapshot, as returned by `GET /auth/me` and
// `PATCH /auth/me` (both share one server-side shape, so this is one parser).
//
// PII: [contactMasked] is a DISPLAY MASK, never the raw identifier — the backend
// deliberately does not ship phone/email (see recapture-api/src/routes/auth.ts
// and utils/maskIdentifier.ts). Nothing here may be logged or sent to analytics:
// the mask still identifies an account. Not persisted to Hive either — it is
// re-fetched per session (see profile_provider.dart).
import 'user_role.dart';

/// Immutable account snapshot for the Profile screen.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.role,
    required this.createdAt,
    this.displayName,
    this.contactMasked,
    this.contactChannel = 'sms',
    this.avatarUrl,
    this.avatarUrlExpiresAt,
  });

  /// Opaque user id.
  final String id;

  /// Access role — mirrors [UserRole]; fail-closed on anything unrecognized.
  final UserRole role;

  /// User-chosen name, or null when never set (the OTP flow never collects one,
  /// so a brand-new account has none).
  final String? displayName;

  /// Display-masked contact identifier (`+91 ••••• ••210` / `a•••@gmail.com`),
  /// or null when the server had nothing safe to show. NEVER the raw value.
  final String? contactMasked;

  /// Which channel [contactMasked] belongs to: 'sms' or 'email'. Defaults to
  /// 'sms' — the primary channel — for an old backend that omits the field.
  final String contactChannel;

  /// Account creation time, in UTC.
  final DateTime createdAt;

  /// SHORT-LIVED presigned URL for the profile picture, or null when none is
  /// set. Derived server-side per response — the backend persists the S3 KEY,
  /// never a URL — so this is a bearer credential with an expiry measured in
  /// about an hour. Never log it, never persist it, never send it to analytics.
  ///
  /// It WILL go stale in normal use (a backgrounded app outlives it), which is
  /// why the avatar degrades to [initials] on an image error rather than to a
  /// broken-image glyph.
  final String? avatarUrl;

  /// When [avatarUrl] stops working, or null when there is no picture. Advisory
  /// — the render path does not gate on it (a clock skew must not hide a
  /// working picture); the errorBuilder fallback is what actually handles
  /// expiry.
  final DateTime? avatarUrlExpiresAt;

  /// True when the account has a display name to render.
  bool get hasDisplayName => (displayName?.trim().isNotEmpty ?? false);

  /// True when there is a picture URL to render. The avatar falls back to
  /// [initials] whenever this is false.
  bool get hasAvatar => (avatarUrl?.isNotEmpty ?? false);

  /// Up to two uppercase initials derived from [displayName] ('Ashish Kuldeep'
  /// → 'AK', 'Ashish' → 'A'), or null when there is no name to derive them
  /// from. Pure — the avatar is drawn from this, never from an asset or a
  /// network image. Rune-based so a leading emoji/astral character yields one
  /// whole glyph rather than half a surrogate pair.
  String? get initials {
    final name = displayName?.trim();
    if (name == null || name.isEmpty) return null;
    final words =
        name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    final first = _firstRune(words.first);
    if (words.length == 1) return first.toUpperCase();
    return '$first${_firstRune(words.last)}'.toUpperCase();
  }

  /// The first whole rune of [word] (never half a surrogate pair).
  static String _firstRune(String word) =>
      String.fromCharCode(word.runes.first);

  /// NOTE (unchanged convention): a null argument MEANS "keep", so this cannot
  /// CLEAR a nullable field. That is fine for the avatar — both mutations
  /// (`uploadAvatar` / `removeAvatar`) return a fresh server snapshot rather
  /// than patching this one, precisely because there is no local URL to invent.
  UserProfile copyWith({
    String? id,
    UserRole? role,
    String? displayName,
    String? contactMasked,
    String? contactChannel,
    DateTime? createdAt,
    String? avatarUrl,
    DateTime? avatarUrlExpiresAt,
  }) {
    return UserProfile(
      id: id ?? this.id,
      role: role ?? this.role,
      displayName: displayName ?? this.displayName,
      contactMasked: contactMasked ?? this.contactMasked,
      contactChannel: contactChannel ?? this.contactChannel,
      createdAt: createdAt ?? this.createdAt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarUrlExpiresAt: avatarUrlExpiresAt ?? this.avatarUrlExpiresAt,
    );
  }

  /// DEFENSIVE parse of the `user` object from /auth/me. EVERY field beyond the
  /// shape itself is optional: an older backend that predates displayName /
  /// contactMasked / contactChannel / avatarUrl must not crash a newer client,
  /// it must just render less (same posture as AuthSession.fromJson). A
  /// missing/ill-typed createdAt degrades to epoch rather than throwing — the
  /// "Member since" line is cosmetic and must never take the screen down.
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final displayName = json['displayName'];
    final contactMasked = json['contactMasked'];
    final contactChannel = json['contactChannel'];
    final createdAtRaw = json['createdAt'];
    final avatarUrl = json['avatarUrl'];
    final avatarExpiryRaw = json['avatarUrlExpiresAt'];

    return UserProfile(
      id: id is String ? id : '',
      role: UserRole.fromApiValue(
        json['role'] is String ? json['role'] as String : null,
      ),
      displayName: displayName is String && displayName.trim().isNotEmpty
          ? displayName.trim()
          : null,
      contactMasked: contactMasked is String && contactMasked.isNotEmpty
          ? contactMasked
          : null,
      contactChannel: contactChannel == 'email' ? 'email' : 'sms',
      createdAt: (createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null)
              ?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      avatarUrl:
          avatarUrl is String && avatarUrl.isNotEmpty ? avatarUrl : null,
      // Advisory only, so an unparseable expiry degrades to null (= "unknown")
      // rather than hiding a URL that in fact still works.
      avatarUrlExpiresAt:
          (avatarExpiryRaw is String ? DateTime.tryParse(avatarExpiryRaw) : null)
              ?.toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          other.id == id &&
          other.role == role &&
          other.displayName == displayName &&
          other.contactMasked == contactMasked &&
          other.contactChannel == contactChannel &&
          other.createdAt == createdAt &&
          other.avatarUrl == avatarUrl &&
          other.avatarUrlExpiresAt == avatarUrlExpiresAt;

  @override
  int get hashCode => Object.hash(
        id,
        role,
        displayName,
        contactMasked,
        contactChannel,
        createdAt,
        avatarUrl,
        avatarUrlExpiresAt,
      );
}
