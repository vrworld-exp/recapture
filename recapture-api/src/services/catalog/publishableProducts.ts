// src/services/catalog/publishableProducts.ts
//
// Which products a FULL publish would actually push. Lifted verbatim out of
// catalogPublishService so the subscription layer (which catalogService
// imports) can count the same list without a require cycle:
//   catalogService → subscriptionService → catalogPublishService →
//   catalogProvisioningService → catalogService.
// Pure, no IO, no model import — the shape is structural on purpose.
import { effectiveModelStatus, isModelPending } from '@/models/types/catalog.types';
import type { ProductModelStatus } from '@/models/types/catalog.types';

/** The minimum a row needs for the two rules below to be decidable. */
export interface PublishableCandidate {
  deletedAt?: Date | null;
  archivedAt?: Date | null;
  modelStatus?: ProductModelStatus;
  assets?: { glbUrl?: string };
}

/** The products a FULL publish would actually push. */
export function publishableProducts<T extends PublishableCandidate>(products: readonly T[]): T[] {
  return products.filter(
    (product) => !product.deletedAt && !product.archivedAt && !isAwaitingFirstModel(product)
  );
}

/**
 * A THREE_D product linked to a model that is still generating, which has never
 * had assets of its own.
 *
 * EXCLUDED FROM PUBLISHING ENTIRELY — from the gates and from the plan — and
 * that exclusion is what makes "the 2D menu is live now, AR arrives per dish"
 * true. Without it a single dish waiting on Meshy would trip
 * PRODUCT_ASSET_MISSING, PRODUCT_THUMBNAIL_MISSING and PRODUCT_MODEL_NOT_READY
 * and block the publish of the WHOLE catalog until generation finished. There
 * is also nothing to send: a 3D item with no model is not a menu item Mirage
 * could render.
 *
 * It joins the menu by itself when catalogModelPromotionService writes its
 * assets and the follow-up run publishes it.
 *
 * ⚠ THE `glbUrl` HALF IS LOAD-BEARING. A product whose REPLACEMENT model is
 * generating still carries its previous model's URLs (see updateProduct's
 * OK_PENDING branch) and is an ordinary publishable product — it renders the
 * old model perfectly well. Only a dish that has never had one is skipped.
 */
export function isAwaitingFirstModel(product: PublishableCandidate): boolean {
  return isModelPending(effectiveModelStatus(product)) && !product.assets?.glbUrl;
}
