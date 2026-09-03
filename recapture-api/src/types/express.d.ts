// src/types/express.d.ts
declare namespace Express {
  interface Request {
    user?: {
      userId: string;
      authUid: string;
      /**
       * Resolved by requireRole via a FRESH DB read (role is deliberately not
       * in the JWT). Present only after requireRole ran.
       *
       * Derived from models/User.ts via an INLINE `import(...)` type, not a
       * top-level import: a top-level import would turn this ambient file into
       * a module and silently drop the global augmentation, while an inline
       * import type keeps it global. It used to restate the union inline, which
       * meant adding SALES_REP to USER_ROLES broke the assignment in
       * requireRole.ts instead of just working.
       */
      role?: import('@/models/User').UserRole;
    };
  }
}
