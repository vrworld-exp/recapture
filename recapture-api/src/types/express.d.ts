// src/types/express.d.ts
declare namespace Express {
  interface Request {
    user?: {
      userId: string;
      authUid: string;
      /**
       * Resolved by requireRole via a FRESH DB read (role is deliberately not
       * in the JWT). Present only after requireRole ran; matches
       * models/User.ts UserRole (kept inline — this ambient declaration file
       * must stay import-free to remain global).
       */
      role?: 'USER' | 'MODEL_ARTIST' | 'ADMIN';
    };
  }
}
