// lib/domain/entities/user_role.dart

/// The signed-in user's access role, mirroring the backend's `User.role`
/// (`USER | MODEL_ARTIST | ADMIN`). Learned from `GET /auth/me` after auth is
/// established; roles are granted server-side only (DB flag) — the client
/// never mutates them.
///
/// Privilege is inclusive upward (admin ⊇ modelArtist ⊇ user) — mirror the
/// backend's rule and never compare roles with exact equality for gating;
/// use [isStaff].
enum UserRole {
  user,
  modelArtist,
  admin;

  /// True for roles that unlock the staff-only surfaces (the Live projects
  /// tab). The default/fallback role [user] never is — a failed role fetch
  /// therefore fails CLOSED.
  bool get isStaff => this != UserRole.user;

  /// Wire value, matching the backend enum exactly.
  String get apiValue => switch (this) {
        UserRole.user => 'USER',
        UserRole.modelArtist => 'MODEL_ARTIST',
        UserRole.admin => 'ADMIN',
      };

  /// Defensive parse — anything unrecognized is [user] (fail-closed).
  static UserRole fromApiValue(String? value) => switch (value) {
        'MODEL_ARTIST' => UserRole.modelArtist,
        'ADMIN' => UserRole.admin,
        _ => UserRole.user,
      };
}
