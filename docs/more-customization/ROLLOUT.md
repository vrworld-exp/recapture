# More-customization — rollout record

Stage 8.3 asks for one line per stage: date shipped, commit, and anything that differed from the
prompt. Everything below is **built, uncommitted and untested** as of 2026-09-30 — fill the
"Shipped" and "Commit" columns as each one actually goes out.

## Order (stage-08 §8.3)

1. **Stage 1 to Mirage first, alone.** Deploy mirage-be + mirage-fe; confirm zero visual change on
   3 live restaurants.
2. **Every later stage: Mirage deploy BEFORE the ReCapture release that sends its fields.** An
   older Mirage ignores fields it does not know, but a newer ReCapture talking to an old Mirage
   means the owner's edits silently do not show.
3. **The switch.** The app hides every customization entry point (Appearance, Badges, Languages,
   Spotlight & buttons, Menu web address, QR style, the product-editor tiles) until ops set
   `appearanceEnabled: true` on the `client_configs` document. Absent = hidden. Turn it on for the
   internal test catalogs (see `learn.txt`), then two friendly clients, then everyone.
4. **Plan gating** stays off with `subscriptionGatesEnabled` (the Stage 5 subscription flag): while
   it is off, every plan gets every customization. Gating turns on with that flag, not separately.
5. **Menu subdomains** need, before anyone saves an address: wildcard DNS `*.<menu domain>` →
   the Mirage-fe host, a wildcard TLS certificate (Vercel supports wildcard domains), Mirage-fe
   `VITE_MENU_DOMAIN=<menu domain>`, recapture-api `MENU_SUBDOMAIN_BASE=<menu domain>`. Without
   the API variable the address is saved but no URL is shown.
6. **Weekly reports (Stage 9)** are off until recapture-api `WEEKLY_REPORTS_ENABLED=true` on the
   WORKER's environment. Deploy mirage-be (new `/analytics/item-funnel`, `/analytics/hourly`, the
   `menu_item_impression` type) and mirage-fe (the impression event) first — without the new
   Mirage endpoints the report still goes out, just with no busiest hour and no "scroll past" tip.
   Turn it on for one test catalog's environment, check Monday's numbers against the analytics
   screen, then everyone. The first Monday after switching on, every published owner gets one.
7. **Offers (Stage 10)**: deploy mirage-be (accepts and returns `restaurant.offers`) and mirage-fe
   (renders them) BEFORE the ReCapture API — an older Mirage silently drops the field, so offers
   saved and published against it never show. No flag: a catalog with no offers sends `''` and
   renders exactly as before.
8. **My plate (Stage 11)** is ON by default in ReCapture, so every menu gains + buttons at its
   owner's next publish after the release. Deploy mirage-be + mirage-fe first (an older Mirage
   drops `plate`, which just means no plate). If you would rather roll it out gradually, flip the
   default in `Catalog.plate` / the profile DTO before shipping.
9. **Stage 12**: deploy mirage-be first (new `optIn` collection + routes; `links` / `customers` on
   the restaurant), then mirage-fe (the `/:restaurant/offers-notice` page must exist before any
   owner switches sign-ups on), then the API + app. Tell owners with a non-Google review link that
   they will need to replace it the next time they save their customer buttons.
10. **Stage 13 (AI)**: deploy mirage-be first (`allowNoImage` on create-item — without it, photo-less
    imported dishes fail to publish). Then set `AI_API_KEY` (an Anthropic API key) on BOTH the API
    and the worker; leave it unset anywhere AI should stay off. Optional: `AI_MODEL`,
    `AI_MONTHLY_BUDGET_INR` (default 2000), `AI_USD_TO_INR` (default 84). Check spend in the
    `aiusages` collection (one row per month, split by purpose).
11. **Stage 14**: API + app only (no Mirage change). Staff sign in with the invited phone number
    through the normal OTP login; tell owners that is how their team gets in. The worker must run
    for "sold out until tomorrow" to come back at 5 am.
12. **Stage 16 (multi-branch)**: API + app only. **Before deploying the API**, run
    `npx tsx scripts/multi-branch/migrate-catalog-index.ts` (dry run, then `--apply`) — rehearse on
    a restored production copy first (16a). If the API boots first, the old `catalogs.userId_1`
    index is kept until `userId_1_branchKey_1` exists, so nothing breaks, but no branch can be added
    until the migration runs. Multi-outlet discounts: give them by hand with the comp / manual
    payment tools (each outlet is billed on its own).
13. **Marketing site** (mayasabhaxr-fe): "Make it yours" section with before/after screenshots of
   2–3 presets — once Stage 3 is live.

## Per stage

| Stage | Shipped | Commit | Differed from the prompt |
|---|---|---|---|
| 1 Theme foundations | | | See stage-01 status. |
| 2 Appearance screen | | | Contrast rule mirrors `applyTheme.ts` (Basalt red 3.96:1). |
| 3 Cover / layout / fonts | | | See stage-03 status. |
| 4 Hours / announcement / windows | | | Hours on their own screen; time-zone not editable yet. |
| 5 Badges / dietary | | | Rep editor has no badge section; ≤ 6 badges per dish. |
| 6 Multi-language | | | Owner types everything (Q3); chrome en + hi only; progress computed in the app. |
| 7 AR / pairings / buttons / QR | | | Dishes published by NAME, not Mirage id; `jsqr` now a runtime dependency; no tests (user). |
| 8 Plan gating / subdomain / rollout | | | Rollout flag served on `GET /catalog/entitlements`, not the strict remote-config payload; no tests (user). |
| 9 Weekly value report | | | Off until `WEEKLY_REPORTS_ENABLED=true`; Mirage adds `/hourly` beside `/item-funnel`; "AR views" = `ar_view_clicked`; notification opens `/catalog/reports/<week>`. |
| 10 Offers / combos / happy hour | | | One `restaurant.offers` block on the branding sync (dishes by name), not a Mirage offer collection; no variants; not flag-gated. |
| 11 My plate | | | Mirage absent = off; ReCapture default on → appears at each owner's next publish; own ungated settings screen. |
| 12 Reviews / customers / links | | | Opt-in under `/analytics/*`, pulled on read; review link Google-only; no Places search; not plan-gated. |
| 13 AI menu import / descriptions / enhance | | | Pages via API not presigned; one call per page; `allowNoImage` on Mirage create-item; fingerprint undo. |
| 14 Today / staff / PDF | | | Ordinary diffed publish (no targeted mode); managers = stock + prices only; PDF Latin-only; not plan-gated. |
| 15 3D spin videos | — | — | Deferred by the owner (2026-09-30). |
| 16 Multi-branch | | | `branchKey` compound index (no `$ne`/`isBranch`); copy-down via the draft bump + `masterSync` snapshot; outlet scope via AsyncLocalStorage; rep `branchName` on activation. |
