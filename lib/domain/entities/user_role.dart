// lib/domain/entities/user_role.dart

/// The signed-in user's access role, mirroring the backend's `User.role`
/// (`USER | SALES_REP | MODEL_ARTIST | ADMIN`). Learned from `GET /auth/me`
/// after auth is established; roles are granted server-side only (DB flag) —
/// the client never mutates them.
///
/// Privilege is inclusive upward (admin ⊇ modelArtist ⊇ salesRep ⊇ user) —
/// mirror the backend's rule and never compare roles with exact equality for
/// gating; use [isStaff] or [isSalesRep].
///
/// DECLARATION ORDER IS THE LADDER. The rank getters below compare `index`, so
/// a member inserted out of order silently changes who passes which gate.
enum UserRole {
  user,
  salesRep,
  modelArtist,
  admin;

  /// True for roles that unlock the staff-only surfaces (the Live projects
  /// tab, backed by /admin). A SALES_REP is NOT staff: it has act-on-behalf-of
  /// writes and no staff surfaces at all, and showing it the Live projects tab
  /// would hand it a screen that answers 403.
  ///
  /// This is a RANK comparison, not `!= user`, precisely so that adding a role
  /// below modelArtist cannot silently widen the gate again. The default/
  /// fallback role [user] never passes — a failed role fetch fails CLOSED.
  bool get isStaff => index >= UserRole.modelArtist.index;

  /// The /rep surface gate. Inclusive upward, mirroring the backend: a
  /// MODEL_ARTIST or ADMIN also passes it (see the note in models/User.ts).
  bool get isSalesRep => index >= UserRole.salesRep.index;

  /// True only for [admin] — the gate for destructive staff actions (e.g.
  /// soft-deleting a captured photo), mirroring the backend's ADMIN-only
  /// `DELETE /admin/projects/:id/photos`. Fails CLOSED for a failed role fetch.
  bool get isAdmin => this == UserRole.admin;

  /// Wire value, matching the backend enum exactly.
  String get apiValue => switch (this) {
        UserRole.user => 'USER',
        UserRole.salesRep => 'SALES_REP',
        UserRole.modelArtist => 'MODEL_ARTIST',
        UserRole.admin => 'ADMIN',
      };

  /// Defensive parse — anything unrecognized is [user] (fail-closed). This is
  /// what makes rolling the backend forward ahead of the client safe.
  static UserRole fromApiValue(String? value) => switch (value) {
        'SALES_REP' => UserRole.salesRep,
        'MODEL_ARTIST' => UserRole.modelArtist,
        'ADMIN' => UserRole.admin,
        _ => UserRole.user,
      };
}
