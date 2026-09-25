// src/routes/webhooks.ts
//
// POST /webhooks/razorpay — Razorpay's server calling ours. No JWT (Razorpay
// has none), no CORS concern (server to server), and the RAW body: app.ts
// mounts this router with `express.raw` ABOVE `express.json`, because the
// signature is an HMAC over the exact bytes and a re-serialised JSON body
// would never verify.
//
// The contract with Razorpay is simple and strict: a bad signature is a 401;
// once the signature is good the answer is 200, whatever happened next.
// Razorpay retries a non-2xx and, after enough of them, DISABLES the webhook
// (E4) — so a business outcome is never an HTTP failure here. Anything that
// throws after verification is logged and left to reconciliation.
import { Router } from 'express';

import { verifyWebhookSignature } from '@/providers/razorpay';
import { handleRazorpayEvent } from '@/services/subscription/webhookService';
import { subscriptionIdOfEvent, syncMandate } from '@/services/subscription/autopayService';
import { asyncHandler } from '@/utils/asyncHandler';
import { track, AnalyticsEvent } from '@/utils/analytics';

const router = Router();

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const body: Buffer = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
    const signature = req.get('X-Razorpay-Signature');

    if (!verifyWebhookSignature(body, signature)) {
      track(AnalyticsEvent.RAZORPAY_WEBHOOK_REJECTED, { reason: 'SIGNATURE' });
      res.status(401).json({
        status: 'error',
        code: 'INVALID_SIGNATURE',
        message: 'Webhook signature did not verify.',
      });
      return;
    }

    let event: unknown;
    try {
      event = JSON.parse(body.toString('utf8'));
    } catch {
      // Signed by Razorpay yet not JSON — nothing we can act on, and nothing
      // a retry would fix. Acknowledged so it is not retried.
      track(AnalyticsEvent.RAZORPAY_WEBHOOK_REJECTED, { reason: 'MALFORMED' });
      res.status(200).json({ status: 'success', ignored: true });
      return;
    }

    try {
      // Autopay: every `subscription.*` event is a cue to SYNC that mandate
      // with Razorpay — the payload is not trusted for state or money, the
      // provider's own answer is (autopayService.syncMandate). An id we never
      // created (a subscription made on the dashboard) is acknowledged.
      const autopayId = subscriptionIdOfEvent(event);
      if (autopayId) {
        const synced = await syncMandate(autopayId, 'WEBHOOK');
        if (synced.kind === 'UNAVAILABLE') throw new Error('autopay sync: provider unavailable');
        res.status(200).json({ status: 'success', ...(synced.kind === 'UNKNOWN' ? { ignored: true } : {}) });
        return;
      }
      const result = await handleRazorpayEvent(event);
      res.status(200).json({ status: 'success', ...(result.ignored ? { ignored: true } : {}) });
    } catch (err) {
      // Never the raw body in the log — only the event name.
      const name =
        typeof event === 'object' && event !== null
          ? String((event as { event?: unknown }).event ?? 'unknown')
          : 'unknown';
      console.error(`[webhook] handler failed for ${name}; reconciliation will retry`, err);
      res.status(200).json({ status: 'success', deferred: true });
    }
  })
);

export default router;
