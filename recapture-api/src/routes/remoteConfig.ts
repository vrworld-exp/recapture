// src/routes/remoteConfig.ts
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { getRemoteConfig } from '@/services/remoteConfigService';
import { strongETag, ifNoneMatchSatisfied } from '@/utils/etag';
import { track, AnalyticsEvent } from '@/utils/analytics';

const router = Router();

// Public on purpose: the client fetches tuning config at startup, possibly
// before login, so there is NO JWT gate here. It serves global config only —
// never user/project data — so there is nothing to authorize.

// Config changes rarely and must reach clients within a few minutes; ETag gives
// instant revalidation, so most repeat hits are a bodyless 304.
const CACHE_CONTROL = 'public, max-age=300';

// This is a hot path (every client startup). Do NOT emit per-request analytics —
// sample a small fraction of 200s so store-degradation (served_defaults) is still
// observable without flooding the pipeline. 304s never emit.
const ANALYTICS_SAMPLE_RATE = 0.01;

/**
 * GET /remote-config — runtime tuning (pitchBands, thresholds, segmentCounts,
 * version). Always answers 200/304 with a schema-valid payload; store problems
 * degrade to baked defaults rather than erroring. Read-only.
 */
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { config, servedDefaults } = await getRemoteConfig();

    const etag = strongETag(config);
    res.setHeader('Cache-Control', CACHE_CONTROL);
    res.setHeader('ETag', etag);

    // Conditional request: unchanged content → 304, no body.
    if (ifNoneMatchSatisfied(req.headers['if-none-match'], etag)) {
      res.status(304).end();
      return;
    }

    if (Math.random() < ANALYTICS_SAMPLE_RATE) {
      track(AnalyticsEvent.REMOTE_CONFIG_SERVED, {
        config_version: config.version,
        served_defaults: servedDefaults,
      });
    }

    res.status(200).json(config);
  })
);

export default router;
