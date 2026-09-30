# ✅ Stage 8 — Plan gating, custom domain, rollout

> **Status (2026-09-30): built, uncommitted. NO tests written or run (user's instruction from
> Stage 7 on).** Type-check / analyze of the touched files is clean. Q4 = the proposed split
> (Basic → Taste, Pro → Signature, Premium → MasterChef); Q5 = our subdomain only.
>
> **8.1 gating** — `services/subscription/customizationEntitlements.ts`: the table (defaults,
> overridable per plan via an OPTIONAL `entitlements` on the plan-catalog override), tier from
> the subscription row (no row / paused / cancelled → Taste; ACTIVE / GRACE → its plan;
> TRIAL / COMPED / PENDING_PAYMENT → everything, the trial is the pitch), behind
> `subscriptionGatesEnabled` (off = everything), fail-open on errors. Enforced AT PUBLISH by
> `services/catalog/entitledView.ts` — restaurant sync and the publish snapshot read the catalog
> as the plan allows it (colours, layout/fonts, badge count, language count, AR branding,
> spotlight, pairings, non-review buttons, section timings, subdomain); the owner's saved
> choices are never touched. `Catalog.publishedEntitlementsKey` + planner reason `PLAN_CHANGED`
> re-push branding and sections after an upgrade / downgrade with no edit (a catalog with no
> recorded key reads as unchanged — no fleet-wide re-push on deploy). Branded QR: the print
> paths (`GET /catalog/qr`, the counted standee download) use the plain style when not covered;
> the preview still shows the design. `heldBack` on `GET /catalog/publish/status`;
> `GET /catalog/entitlements` for the app. Flutter: `PlanLockChip` / `EntitlementLock` /
> `EntitlementLimitNote` on Appearance (colours, layout, fonts), 3D & AR style, Spotlight,
> Customer buttons, QR style, Menu languages, Badges, "Goes well with", Menu web address;
> a "Held back on your plan" card on the publish screen. **Not locked in the app:** the section
> timing editor in the category managers (it is still held back at publish and listed).
>
> **8.2 subdomain (phase 1)** — `Catalog.slug` (unique partial index, `[a-z0-9-]{3,40}`, no
> `--`, reserved list), `PUT /catalog/slug`, `slug` / `slugUrl` on the profile DTO, env
> `MENU_SUBDOMAIN_BASE`. Published to Mirage `restaurant.slug` (sparse unique) only on a plan
> with `customDomain`; public `GET /resolve-slug/:slug` (published restaurants only).
> Mirage-fe `SubdomainHome` on `/`: on `<slug>.<VITE_MENU_DOMAIN>` resolves and navigates to
> `/<restaurant name>` — the same route the QR's URL uses. `publicUrl` is never touched.
> Flutter `menu_address_screen.dart` (catalog ⋮ → Menu web address). Needs wildcard DNS + TLS.
>
> **8.3 rollout** — see [ROLLOUT.md](ROLLOUT.md). Flag `appearanceEnabled` on `client_configs`,
> served on `GET /catalog/entitlements` (NOT in the strict remote-config payload, where a new
> key risks the whole config falling back to defaults). The app hides the entry points only when
> the server says `false` (which it does while the flag is absent); on an API error it shows
> them. Marketing-site section not done (waits for Stage 3 to ship).

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
| Offers / happy hour (Stage 10) | — | ✅ | ✅ |
| My plate (Stage 11) | — | ✅ | ✅ |

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
