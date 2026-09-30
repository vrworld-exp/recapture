// src/routes/staff.ts
//
// `/staff` — the area a restaurant's own MANAGER or STAFF use (more-customization
// Stage 14.3). Any signed-in user may call it; what they may touch is decided by
// their CatalogDelegation grant, read fresh on every request, so an owner's
// revoke works on the very next call. There is deliberately nothing here for
// appearance, subscription, billing, customers or the PDF.
import { Router } from 'express';

import { requireAuth } from '@/middleware/auth';
import { todayRouter } from '@/routes/todayRoutes';
import { myStaffCatalogs, resolveStaffCatalog } from '@/services/staff/staffService';
import { asyncHandler } from '@/utils/asyncHandler';

const router = Router();
router.use(requireAuth);

/** GET /staff/catalogs — the restaurants I help run (claims pending invites first). */
router.get(
  '/catalogs',
  asyncHandler(async (req, res) => {
    res.status(200).json({ status: 'success', catalogs: await myStaffCatalogs(req.user!.userId) });
  })
);

router.use(
  '/catalogs/:id',
  todayRouter(
    async (req) => resolveStaffCatalog(req.user!.userId, String(req.params.id)),
    (res) =>
      res
        .status(404)
        .json({
          status: 'error',
          code: 'CATALOG_NOT_FOUND',
          message: 'That restaurant was not found.',
        })
  )
);

export default router;
