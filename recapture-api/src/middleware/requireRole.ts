// src/middleware/requireRole.ts
//
// Minimum-role gate for staff routes. Runs strictly AFTER requireAuth (it
// reads req.user.userId) and resolves the caller's role with a FRESH DB read
// on every request — the role is deliberately NOT a JWT claim, so a grant or
// revocation via scripts/set-user-role.ts applies on the very next request,
// not at token expiry.
//
// Responses use the STANDARD envelope (unlike the legacy shape still in
// middleware/auth.ts — do not copy that one). Role comparison is inclusive
// upward via hasRoleAtLeast (ADMIN passes every MODEL_ARTIST gate); exact
// equality checks are a bug by convention.
import { RequestHandler } from 'express';
import { User, hasRoleAtLeast, type UserRole } from '@/models/User';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';

export function requireRole(minRole: UserRole): RequestHandler {
  return (req, res, next) => {
    const userId = req.user?.userId;
    if (!userId) {
      // requireAuth was not mounted before this — treat as unauthenticated
      // rather than leaking a 500.
      res.status(401).json({
        status: 'error',
        code: 'UNAUTHENTICATED',
        message: 'Authentication required.',
      });
      return;
    }

    User.findById(userId)
      .select('role')
      .exec()
      .then((user) => {
        // A token whose user vanished is an auth failure, not a role failure.
        if (!user) {
          res.status(401).json({
            status: 'error',
            code: 'UNAUTHENTICATED',
            message: 'Invalid or expired token.',
          });
          return;
        }

        if (!hasRoleAtLeast(user.role, minRole)) {
          track(AnalyticsEvent.ADMIN_ACCESS_DENIED, {
            actor_id_hash: hashIdentifier(userId),
            route: `${req.method} ${req.baseUrl}${req.path}`,
          });
          res.status(403).json({
            status: 'error',
            code: 'FORBIDDEN',
            message: 'You do not have access to this resource.',
          });
          return;
        }

        req.user = { ...req.user!, role: user.role };
        next();
      })
      .catch(next);
  };
}
