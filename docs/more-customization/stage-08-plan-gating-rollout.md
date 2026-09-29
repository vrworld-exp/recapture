# Stage 8 — Plan gating, custom domain, rollout

**Side:** recapture-api + Flutter + Mirage + infra.
**Depends on:** whichever of Stages 1–7 are being gated.
**Size:** M

---

## 8.1 Plan gating (answer Q4 first)

Customization is a strong reason to upgrade. Gate it with the **existing** plan catalog
(`recapture-api/src/config/subscriptionPlans.ts`, served through `/remote-config`) — add an
`entitlements` block per plan rather than a new system.

Proposed split:

| Feature | Basic | Pro | Premium |
|---|---|---|---|
| Theme presets (Stage 2) | ✅ | ✅ | ✅ |
| Custom primary/accent colours | — | ✅ | ✅ |
| Cover image, layout, fonts (3) | cover only | ✅ | ✅ |
| Hours, announcement (4.1, 4.2) | ✅ | ✅ | ✅ |
| Time-windowed categories (4.3) | — | ✅ | ✅ |
| Badges / dietary / filters (5) | 3 badges | ✅ | ✅ |
| Extra languages (6) | — | 1 | 3 |
| AR branding, spotlight (7.1, 7.2) | — | ✅ | ✅ |
| Engagement buttons (7.3) | review link | ✅ | ✅ |
| Branded QR (7.4) | — | ✅ | ✅ |
| Custom domain (8.2) | — | — | ✅ |

Rules:

1. **Enforce at publish, not at save.** The owner can design anything and see it in the preview;
   `syncCatalogBranding()` / the worker **strips** un-entitled fields (sends the default) and the
   publish result lists what was held back ("Custom colours need Pro"). Never fail the whole publish.
2. Enforcement is behind the same `subscriptionGatesEnabled` flag as the rest of Stage 5 of the
   subscription pack — flag off = everything allowed.
3. Downgrade / lapse: next publish (or the subscription page-state processor) resets gated fields
   on Mirage to defaults. The owner's saved choices stay in ReCapture, so upgrading restores them.
4. App shows a lock + "Pro" chip on gated controls, tapping opens the subscription screen.
5. Respect the client-side publish paywall rules already in place (memory: fail-open).

## 8.2 Custom domain / subdomain (answer Q5 first)

- **Phase 1 — our subdomain**: `Catalog.slug` (unique, `[a-z0-9-]{3,40}`, reserved-word list) →
  `https://<slug>.<menu-domain>` served by the same Mirage-fe build. Wildcard DNS + wildcard TLS
  on the host (Vercel supports wildcard domains). Mirage-fe resolves slug → restaurant id via a new
  public endpoint.
- ⚠ **Never change `catalog.publicUrl`** — printed QRs point at it (`assertMappingImmutable`). The
  slug URL is an **additional** address; the QR keeps working. The rep/owner may print new QRs
  with the pretty URL if they choose.
- **Phase 2 — client's own domain**: CNAME to us + domain verification + host API to attach
  the domain and issue TLS. Premium only. Separate design when Phase 1 is proven.

## 8.3 Rollout

1. Stage 1 to Mirage first, alone; confirm zero visual change on 3 live restaurants.
2. Stage 2 behind a remote-config flag `appearanceEnabled` (absent = hide the Appearance tile).
   Turn on for internal test catalogs (see test accounts in `learn.txt`), then 2 friendly clients.
3. Each later stage: Mirage deploy **before** the ReCapture release that sends the field.
4. Record, per stage, in this folder: date shipped, commit, anything that differed from the prompt.
5. Marketing site (mayasabhaxr-fe): add a "Make it yours" section with before/after screenshots of
   2–3 presets once Stage 3 ships.

## Done when

- [ ] Basic-plan catalog with custom colours publishes with default colours and a clear "held back" note.
- [ ] Upgrading and re-publishing applies the saved colours with no re-editing.
- [ ] `<slug>.<menu-domain>` and the original QR URL open the same menu.
