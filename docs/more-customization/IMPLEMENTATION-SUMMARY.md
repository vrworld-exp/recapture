# More Customization: Implementation Summary (Stages 1–16)

A walkthrough of everything built in the more-customization programme: what each stage gives
restaurants, how it works, where the code is, what we chose differently from the original plan,
and how it was tested. The per-stage docs in this folder have the full detail. This page is the
overview.

**State as of 2026-09-30:** Stages 1–14 and 16 are built, tested and committed (ReCapture
`ba7b0cc`). Stage 15 (3D spin videos) is deferred by the product owner. Nothing is switched on in
production yet. The rollout order is in [ROLLOUT.md](ROLLOUT.md).

---

## 1. Why we did this

Every Mirage menu looked the same: one dark "Basalt" page with hardcoded colours and a different
logo on top. Restaurants want their menu to feel like their own, and they want features that
help their business, not only a digital menu.

- **Part 1 (Stages 1–8)** makes the menu brandable: colours, cover, fonts, hours, badges,
  languages, AR look and QR. Stage 8 then ties all of it to the subscription plans.
- **Part 2 (Stages 9–16)** adds features that bring value: a weekly report, offers, "My plate",
  reviews and a customer list, AI menu import, quick daily edits and staff access, and
  multi-branch restaurants.

## 2. Architecture rules that apply to every stage

These are the decisions everything else rests on (README D1–D7).

| Rule | What it means in practice |
|---|---|
| **ReCapture is the source of truth.** | Owners (or reps) author everything in the ReCapture app. The API stores it on `Catalog`, `CatalogProduct` or `CatalogCategory`. Mirage only stores a copy and renders it. |
| **Changes go live on Publish.** | Every authoring write bumps `draftRevision`, which shows "unpublished changes". Publish pushes the restaurant fields (`syncCatalogBranding()`) and only the changed dishes (diffed planner). No edit reaches customers instantly. |
| **Absent = today's page.** | Every new field is optional on all four sides. A restaurant that customised nothing renders exactly as before, so no migration was needed for existing restaurants. |
| **Presets, not free CSS.** | Looks are presets plus contrast-checked colour overrides (WCAG AA 4.5:1), checked in ReCapture and re-checked in Mirage-fe. |
| **Time is checked in the browser, in the restaurant's zone.** | "Open now", scheduled announcements, section timings and happy hours are evaluated in the menu page using `Asia/Kolkata`. No server cron is needed. |
| **Dishes referenced by published name.** | Spotlight, pairings and offers point at dishes by name, not by Mirage id, so a dish created in the same publish still resolves (Stage 7 onwards). |
| **Gating at publish, not at save.** | Owners can always save a customisation. The publish sends only what their plan covers (Stage 8). |

**The four codebases**

| Side | What changed |
|---|---|
| `recapture-api` (Node / Express / Mongoose, TS) | Models, validation, services, routes, publish sync, worker jobs |
| ReCapture app (Flutter) | Every owner and rep screen |
| `mirage-be` (Express / Mongoose, JS) | New stored fields, public payload, analytics events and reports |
| `mirage-fe` (React / Vite / Tailwind) | Rendering: themes, hours, badges, offers, plate, sign-up and more |

---

## 3. Part 1: Make every menu its own restaurant

### Stage 1 — Theme foundations (Mirage only)
- **What it does:** makes the menu's colours data-driven with zero visual change. This is the
  base for every later look.
- **How:** hardcoded Tailwind hex colours became CSS variables (`--c-bg`, `--c-primary`, …).
  Class names are unchanged. Presets live in `mirage-fe/src/theme/presets.ts`, and
  `applyTheme.ts` applies them. A boot script in `index.html` applies the cached theme before
  first paint, so there is no flash of the default look. Mirage-be gained a `theme` field
  (`parseThemeField`).
- **Tests:** mirage-fe `applyTheme.test.ts`, mirage-be `theme.test.js`.

### Stage 2 — Appearance screen in ReCapture
- **What it does:** the owner (or a rep for them) picks a preset, optionally a primary and accent
  colour, sees a live phone preview, and publishes.
- **How:** `Catalog.appearance` = `{ presetId, mode, primary, accent }` (the whole block is
  replaced on save; `null` resets it). `config/themePresets.ts` mirrors the Mirage-fe presets, and
  the app receives them through `/remote-config`, so new presets need no app release. Contrast is
  checked in `utils/colorContrast.ts` (`APPEARANCE_LOW_CONTRAST`). Flutter:
  `appearance_screen.dart` and `menu_theme_preview.dart`.
- **Tests:** api `catalog-appearance.test.ts`, flutter `appearance_test.dart`.

### Stage 3 — Cover image, layout, fonts
- **What it does:** a hero cover banner, three card layouts (grid, list, large) and curated font
  pairings.
- **How:** the cover upload already existed but never reached Mirage. It is now sent as its
  CloudFront URL (`coverUrl`), so there is no re-upload. `appearance.layout` and
  `appearance.fontId`; fonts are loaded from Google Fonts only when not the default. New
  `MenuItemRow.tsx` (list) and a `large` card variant.
- **Choices:** the hero scrolls away above the sticky header and loads eagerly (it is above the
  fold, which is better for LCP). A per-section layout override was deferred.
- **Tests:** mirage-fe `MenuLayouts.test.tsx` and `fonts.test.ts`.

### Stage 4 — Opening hours, announcements, timed sections
- **What it does:** an "Open · closes 11 pm" chip and a weekly table; an announcement strip
  (info, offer or alert, schedulable); sections that hide or dim outside their hours (for example
  Breakfast).
- **How:** `Catalog.hours`, `Catalog.announcement`, and `CatalogCategory.schedule` /
  `outsideWindow`. Mirage-be `helper/timeFields.js` (the block is replaced; `""` clears it).
  Mirage-fe `hours.ts` uses `Intl` in the restaurant's zone, never the phone's. Flutter
  `opening_hours_screen.dart`, the announcement editor, and "Available times" in the section
  managers.
- **Tests:** api `catalog-time-fields.test.ts`, mirage-fe `hours.test.tsx`, mirage-be
  `timeFields.test.js`.

### Stage 5 — Custom badges and diet / allergen info
- **What it does:** the owner designs up to 12 badges (Bestseller, Chef's special, …) and puts
  them on dishes. Dishes gain diet labels, allergens, spice level, calories, serving size and prep
  time. Diners can filter by diet.
- **How:** `Catalog.badges` (the server assigns ids; deleting a badge removes it from dishes in the
  same request). Dish fields are validated (`UNKNOWN_BADGE`, `DIET_CONFLICT` such as Vegan with
  Dairy). They are published as one diffed field, `details`, with badges resolved, so a badge
  rename republishes only the dishes that carry it.
- **Tests:** api `catalog-badges-dietary.test.ts`, mirage-fe `dishDetails.test.tsx`, mirage-be
  `dishDetailFields.test.js`.

### Stage 6 — Multi-language menu
- **What it does:** up to 3 extra languages per menu from 9 Indian languages. Diners switch
  language; dish names, descriptions, sections, badges and the announcement are translated, and
  the primary text is shown where a translation is missing.
- **How:** translations sit beside the original fields (`i18n` on product, category and catalog).
  Catalog-level text lives in `Catalog.i18n[lang]` so the Stage 4 and 5 editors cannot overwrite
  it. The owner types every translation, with no machine translation (a product decision). The
  menu's own labels ("View in AR", "Sold out") are translated by Mirage-fe in English and Hindi.
- **Tests:** api `catalog-languages.test.ts`, flutter `menu_languages_test.dart`, mirage-fe
  `languages.test.tsx`, mirage-be `i18nFields.test.js`.

### Stage 7 — AR branding, pairings, customer buttons, branded QR
- **What it does:**
  - The 3D viewer carries the restaurant's logo loader, watermark and backdrop.
  - "Chef's spotlight" and "Goes well with" pairings.
  - Customer buttons: Rate us, WhatsApp order, Call waiter, Wi-Fi, feedback form.
  - A branded QR: colours, logo and four print templates.
- **How:** `Catalog.arBranding`, `spotlight`, `engagement`, `qrStyle`, and
  `CatalogProduct.pairsWith` (up to 4). The feedback form uses a Mirage `feedbackModel` and
  `POST /analytics/feedback`, rate-limited with one per visitor per day. **Every styled QR is
  decoded with jsQR before it is served. If it does not scan, the plain QR is served instead.**
- **Choice:** spotlight and pairings reference dishes by NAME (see section 2).
- **Tests:** api `catalog-qr.test.ts`, `rep-catalog-qr.test.ts`, flutter `qr_screen_test.dart`.
  The rep test caught a drift in the rep QR route, fixed in Stage 14 with a shared
  `printableQr.ts`.

### Stage 8 — Plan gating, menu web address, rollout switch
- **What it does:** ties customisation to the plans. Taste (Basic) gets the basics, Signature
  (Pro) gets more, MasterChef (Premium) gets everything. Trial, comped and pending-payment
  restaurants get everything, because the trial is the sales pitch.
- **How:** `services/subscription/customizationEntitlements.ts` is the entitlement table.
  `services/catalog/entitledView.ts` gives the publish a plan-filtered view of the catalog; the
  owner's saved choices are never deleted. After an upgrade or downgrade,
  `publishedEntitlementsKey` re-pushes the branding with no edit needed (reason `PLAN_CHANGED`).
  The app shows lock chips and a "Held back on your plan" card on the publish screen.
- **Menu web address:** `Catalog.slug` gives `yourname.<menu domain>`. It is only on plans with
  that entitlement, and the printed QR URL (`publicUrl`) is never changed.
- **Safety switches:**
  - Gating runs behind the existing `subscriptionGatesEnabled` flag (off = everything allowed) and
    fails open on errors.
  - The whole customisation UI hides behind `appearanceEnabled` until we switch it on.

---

## 4. Part 2: Features that bring value to the restaurant

### Stage 9 — Weekly value report and insights
- **What it does:** every Monday the owner gets a report for the week: menu views, visitors, QR
  scans, AR views, top dishes, busiest hour, a daily chart and a heat strip. It includes up to 2
  practical tips (for example "Your AR dishes get 3× more views — add 3D to X").
- **How:** new Mirage events (`menu_item_impression`: 50% visible for at least 1 s) and reports
  (`/analytics/item-funnel`, `/analytics/hourly`). API `models/WeeklyReport.ts` (unique per
  catalog and week), `services/insights/rules.ts` (7 pure rules), and a worker job
  `WEEKLY_REPORT` fed by a periodic sweep. It is delivered in the app now; WhatsApp comes later.
  Reps get a read-only view.
- **Switch:** env `WEEKLY_REPORTS_ENABLED` is off by default. The plan is to switch it on for one
  test restaurant first.
- **Tests:** api `weekly-report.test.ts` (week boundaries, every rule, idempotent delivery,
  opt-out, quiet week).

### Stage 10 — Offers, combos, happy hour
- **What it does:** percent-off, fixed-price and combo offers on a dish, a section or the whole
  menu, with day and time windows. The menu shows struck-through prices, a top strip and an
  Offers pill live, minute by minute.
- **How:** API `models/CatalogOffer.ts`, `catalogOffersService.ts` (CRUD, preview, a 20-active
  cap). **Offers travel as one `restaurant.offers` block on the branding sync, with dishes by
  name.** There is no separate Mirage offer collection. The price logic exists twice (API and
  Mirage-fe), so both are tested against **one shared test-case file** (`offer-vectors.json`,
  21 cases) to guarantee the owner's preview and the diner's price always agree.
- **Plan:** Signature and above (new `offers` entitlement).
- **Tests:** api `catalog-offers.test.ts`, mirage-fe `offers.test.tsx`.

### Stage 11 — "My plate"
- **What it does:** diners tap + on dishes to build a plate, see a running total (offer prices
  included), then "Show to waiter" (a clean large-text view) or send it on WhatsApp. The table
  number comes from the QR (`?t=`).
- **How:** mirage-fe `features/plate/` (stored per restaurant in localStorage, cleared after 4 h)
  and `Catalog.plate = { enabled, showTotal }`. Stats (plates built, average value, top dish)
  appear in analytics and the weekly report.
- **Choices:** ON by default in ReCapture, so it appears at each owner's next publish. Owners
  switch it off on their own screen, which is always visible. Mirage treats a missing setting as
  OFF, so no menu changes until it is published.
- **Plan:** Signature and above (new `plate` entitlement).
- **Tests:** mirage-fe `plate.test.tsx`.

### Stage 12 — Reviews, customer list, delivery and booking links
- **What it does:**
  - A timed "Enjoyed your meal? Rate us on Google" prompt. **It never gates by star rating**, as
    Google's policy requires.
  - A customer sign-up for offers with explicit consent, following DPDP. The owner gets a
    customer list with birthdays this week, WhatsApp chat, CSV export and opt-out.
  - Zomato and Swiggy "Order online" chips and a "Book a table" button.
- **How:**
  - Opt-ins are stored in Mirage (`optInModel`, public `POST /analytics/opt-in` and `opt-out`,
    rate-limited). The consent box starts unticked and the exact consent words are stored.
  - ReCapture pulls opt-ins into `CustomerContact` when the owner opens the list.
  - Contacts are kept for 24 months. The CSV contains subscribed customers only and is guarded
    against formula injection, and every export is audit-logged.
  - Review links must be Google links.
  - Owner-only: reps cannot see customers.
- **Tests:** api `customers-links.test.ts`, mirage-fe `stage12.test.tsx`, flutter
  `stage12_links_test.dart`.

### Stage 13 — AI menu import, descriptions, photo enhance
- **What it does:**
  - Photograph or upload a paper or PDF menu, and AI reads it into a draft (sections, dishes,
    prices). The owner reviews, applies it in one step, and can undo.
  - AI writes dish descriptions in the restaurant's tone (casual, premium or fun).
  - "Enhance photo" straightens, crops and brightens dish photos.
- **How:**
  - `src/modules/ai/provider.ts` calls Claude (`claude-opus-5-5`) through the official Anthropic
    SDK with structured, schema-validated output. The output is re-validated and cleaned before
    use.
  - **Cost control:** `budget.ts` and `AiUsage` enforce a hard **₹2,000/month** cap across all
    restaurants, plus 5 imports per day per restaurant. Without `AI_API_KEY`, every AI button is
    hidden.
  - The import runs as a worker job, one AI call per page. Uploaded menu photos are purged after
    30 days.
  - Photo-less imported dishes can publish (new opt-in `allowNoImage` on Mirage create-item).
  - Photo enhance uses `sharp`, with no AI.
- **Who:** reps and owners on every plan.
- **Tests:** api `menu-import-ai.test.ts` (the AI is faked, with no network calls), flutter
  `stage13_import_test.dart`.

### Stage 14 — Today screen, staff access, printable PDF menu
- **What it does:**
  - A "Today" screen for fast daily edits: mark sold out (or "sold out until tomorrow", which
    comes back automatically at 05:00 IST), change prices, and publish.
  - Bulk price change (percent or flat, with rounding), with a preview and a 7-day undo.
  - **Staff access:** the owner invites staff by phone as Manager (stock + prices + publish) or
    Staff (stock + publish). Access is re-checked on every request, so removal works immediately.
  - A printable PDF menu in three templates with an optional QR.
- **How:** `services/todayService.ts`, `models/CatalogChangeLog.ts` (who changed what, 90-day
  expiry), `CatalogDelegation.kind` = REP | MANAGER | STAFF (existing rep grants read as REP, so
  staff can never reach rep screens), `services/staff/*`, `services/menuPdfService.ts`. The
  helpers' area is `/staff`.
- **Limits:** the PDF prints Latin text only (Hindi needs an embedded font). Managers cannot do
  full dish editing. Staff access is not plan-gated.
- **Tests:** api `today-staff-pdf.test.ts` (the full permission matrix over HTTP), flutter
  `stage14_today_test.dart`.

### Stage 15 — 3D spin videos: deferred
Not built, by product decision (2026-09-30). The design doc is kept for later.

### Stage 16 — Multi-branch restaurants
- **What it does:** one owner runs a main outlet plus up to 10 branches. Each branch has its own
  menu page, QR standees, stock, prices, staff, offers and subscription. The **menu and the look
  are set once on the main outlet and flow to every branch automatically.** A branch can still set
  its own price or stock for a dish, and keeps that override.
- **Decisions (answered 2026-09-30):**
  - Demand: 2–5 clients.
  - Billing: per outlet. A multi-outlet discount is given by hand with the comp tools.
  - Theme: brand-wide only.
  - Standees: one pool per outlet.
- **Why this design:** the original idea (one master menu merged at publish time) would have meant
  rewriting about 50 places that assume one catalog per owner. Instead:
  1. **Every branch is an ordinary Catalog.** Publish, Today, staff, offers, reports and QR
     already work per catalog, so they needed no change.
  2. **Copy-down:** every edit already ends in a draft bump. For a main outlet, that bump now also
     reconciles its branches (`services/brand/copyDown.ts`). The reconcile is idempotent and only
     applies differences.
  3. **Overrides without extra bookkeeping:** each branch dish remembers what was last copied to
     it (`masterSync`). A field that differs from that was changed by the branch, and is left
     alone. "Reset to main outlet" re-copies it.
  4. **Which outlet am I editing?** The app sends an `X-Outlet-Id` header. The API resolves it
     per request (`services/catalog/outletScope.ts`, using AsyncLocalStorage). The owner id stays
     in every query, so another owner's outlet id matches nothing. No header means the main
     outlet, so existing clients and single-outlet restaurants behave exactly as before.
- **Other pieces:**
  - Branch images are copied to the branch's own storage path, so cleanup never deletes the main
    outlet's photos.
  - Brand-wide fields are refused on a branch (`BRAND_WIDE_FIELD`).
  - A main outlet with branches cannot be deleted (`HAS_BRANCHES`).
  - ~~"Publish all outlets"~~ — removed 2026-10-04 (button and `POST /catalog/outlets/publish-all`):
    each outlet is published from its own catalog screen, through its own plan check.
  - Reps can activate a standee as a new branch (`branchName`).
  - The main outlet's weekly report shows an "All outlets" line.
  - App: an outlet switcher, an Outlets screen, locked brand screens on a branch, and a "From
    main outlet" card with Reset in the dish editor.
- **Database change (the one risky step):** the unique index `{ userId }` (one catalog per owner)
  became `{ userId, branchKey }` (one main catalog per owner plus uniquely named branches). The
  migration script `scripts/multi-branch/migrate-catalog-index.ts` builds the new index first,
  drops the old one after, is idempotent, and dry-runs by default. **It must be rehearsed on a
  copy of production before going live.**
- **Tests:** api `multi-branch.test.ts` (11 cases: indexes, migration, copy-down and overrides,
  archive, brand-wide copy, outlet scope incl. foreign outlets → 404, publish-all, rep branch
  activation, report roll-up), flutter `outlets_test.dart` (5).

---

## 5. Testing summary (full run, 2026-09-30)

| Suite | Result |
|---|---|
| recapture-api (vitest) | 2,179 of 2,182 passed. 1 stale test was fixed afterwards; the other 2 fail only with the local `.env` test prices and pass with default values. |
| ReCapture app (flutter test) | 3,446 pass, 1 skipped |
| mirage-fe (vitest) | 123 pass, typecheck clean |
| mirage-be (node --test) | 20 pass |

Two notes on the API run:
- **Local `.env` settings affect the run.** A few subscription tests fail when the local `.env`
  sets test prices or a longer payment window. The suite was run with the default values, and
  there are no code failures.
- **Stale tests fixed after later stages:** one test pinned the old catalog index (after
  Stage 16), and one pinned the analytics summary keys (after Stage 11). Both were updated.

Tests exercise the logic and the APIs. **Manual checks on real phones and against a live Mirage
have not been done yet.** They are part of the rollout steps.

---

## 6. Before we switch things on in production

Full order in [ROLLOUT.md](ROLLOUT.md). The main points:

1. **Deploy order:** Mirage-be, then Mirage-fe, then API, then the app. Every new field is
   optional, so the old and new versions work together during the deploy.
2. **Stage 16 index migration:** rehearse on a restored production copy, then run the script
   before the API deploy.
3. **Switches, all off or controlled today:**

   | Switch | Controls |
   |---|---|
   | `appearanceEnabled` (client config) | The customisation screens |
   | `subscriptionGatesEnabled` | Plan gating |
   | `WEEKLY_REPORTS_ENABLED` | Weekly report (one test restaurant first) |
   | `AI_API_KEY` | AI features |
   | `MENU_SUBDOMAIN_BASE` + wildcard DNS / TLS | Menu web address |

4. **Behaviour owners will notice:**
   - My plate appears at each restaurant's next publish (default ON on covered plans).
   - Non-Google review links must be replaced the next time the owner saves customer buttons.
5. **Legal and policy:**
   - The review prompt must never filter by rating (Google policy).
   - Customer sign-up follows DPDP consent: explicit tick, stored consent text, easy opt-out,
     24-month retention.

## 7. Open items and future work

- **Q1 (preset list) and Q2 (rep access to Appearance):** answered provisionally; final sign-off
  pending.
- **Stage 15 (3D spin videos):** deferred.
- **Not built yet:**
  - WhatsApp delivery of the weekly report and bulk WhatsApp sends.
  - Hindi PDF menus.
  - Full dish editing for Managers.
  - Rep-side badge / diet editor and the ✨ AI button in the rep dish editor.
  - Mirage "Our other branches" list.
  - Remembering the selected outlet across app restarts.
- **Not decided yet:** plan gating for Stage 12 (customers) and Stage 14 (staff).
- **Pricing and ops:** a brand plan (one bill for N outlets) is not built, and the ₹2,000/month
  AI cap should be reviewed after a month of real use.

---

*Detailed per-stage docs: `stage-01-…md` to `stage-16c-…md` in this folder. Each has a status block
listing the exact files and every way the build differs from the original plan.*
