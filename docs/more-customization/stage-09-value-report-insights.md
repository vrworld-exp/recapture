# Stage 9 — Weekly value report + dish insights

**Side:** recapture-api (worker + service) + Flutter + small Mirage-fe events.
**Depends on:** nothing in this pack (uses the existing analytics system).
**Size:** L
**Priority:** ⭐ #1 of the "useful features" — this is what makes an owner renew.

## Why

An owner pays every month but never *sees* what Mirage did for them. A paper menu gives them no
data at all; we already collect a lot (`mirage-be/src/Models/analyticsEventModel.js` events,
`QrScanDaily` scan counts, `catalogAnalyticsService.ts` proxying Mirage `/me/summary`,
`/me/timeseries`, `/me/top-products`). This stage turns that into a short, human report the owner
reads in 20 seconds, every week, without opening a dashboard.

## What the owner gets

**Every Monday 10:00 IST**, an in-app notification (and WhatsApp once that channel exists):

```
📊 Café Mocha — last week (22–28 Sep)
👀 1,240 menu views  (▲ 18% vs previous week)
📱 412 QR scans · 310 AR views
🏆 Top dish: Paneer Tikka (182 views)
⏰ Busiest: Saturday 8–9 pm
💡 Tip: "Cold Coffee" is viewed a lot but has no photo — add one.
[ See full report ]
```

Tapping opens a **Weekly report** screen in ReCapture with the same numbers plus charts.

---

## Part A — the numbers (recapture-api)

New `services/weeklyReportService.ts` — `buildWeeklyReport(catalogId, weekStart)` returns:

| Metric | Source | Notes |
|---|---|---|
| `menuViews` | Mirage `/me/summary` `client_page_view` | range = Mon 00:00 → Sun 23:59 IST (reuse the zone handling in `catalogAnalyticsService.ts:52`) |
| `uniqueVisitors` | summary `visitorId` distinct | |
| `qrScans` | `QrScanDaily` sum for the catalog's assignments | only counts pre-printed standee scans |
| `arViews` | `ar_session_started` count | |
| `topDishes[3]` | `/me/top-products` by `product_detail_opened` | map Mirage item id → `CatalogProduct` via `mirageItemId` |
| `busiestSlot` | `/me/timeseries` hourly buckets, day-of-week × hour max | |
| `deltaPct` | same metrics for previous week | `null` if previous week had < 20 views (avoid "▲ 400%" on tiny numbers) |
| `tips[≤2]` | insight rules (Part B) | |

Store each built report in a new `WeeklyReport` model
`{ catalogId, weekStart: 'YYYY-MM-DD', metrics, tips, createdAt }`, unique on
`(catalogId, weekStart)` — the unique index is the dedupe, same pattern as `ReminderLog`.

## Part B — insight rules ("tips")

Pure functions in `services/insights/rules.ts`, each `(ctx) => Tip | null`, ranked by
`priority`; the report picks the top 2. Ship these first:

| id | Rule | Tip text |
|---|---|---|
| `NO_PHOTO_POPULAR` | a top-10 viewed dish has no image | "“{dish}” is popular but has no photo — add one." |
| `HIGH_VIEW_LOW_OPEN` | card impressions high, detail opens < 5% | "Many people scroll past “{dish}”. Try a better photo or price." |
| `AR_OUTPERFORMS` | 3D dishes get ≥ 2× the detail opens of photo dishes | "Your 3D dishes get {n}× more attention. Add 3D to “{dish}”?" (→ upsell to model generation) |
| `SOLD_OUT_VIEWED` | an OUT_OF_STOCK dish was opened > 20 times | "“{dish}” was sold out but 34 people looked at it." |
| `NO_DESCRIPTION` | top dish missing description | "Add a description to “{dish}” — it's your #2 dish." |
| `DRAFT_NOT_PUBLISHED` | `draftRevision > publishedRevision` for > 3 days | "You have unpublished changes." |
| `SEARCH_NO_RESULT` | `search_performed` terms with 0 results ≥ 5 times | "Customers searched “{term}” and found nothing." |

`HIGH_VIEW_LOW_OPEN` needs a **card impression** event that does not exist yet → Part D.

## Part C — delivery (worker)

- New processor `weeklyReportProcessor.ts` registered in `processorRegistry.ts`, scheduled by the
  same sweep mechanism the subscription reminders use. Runs Monday 09:30 IST, fans out one job per
  **published, not deleted** catalog, builds + stores the report, then creates a `Notification`
  (`kind: 'INFO'`, `audienceType` = the owner, `action: { label: 'See report', url: 'recapture://reports/<weekStart>' }`).
- Skip catalogs with < 10 views that week (send a friendlier "Place your QR where customers can
  see it" tip at most once a month instead).
- Owner setting `Catalog.reportPrefs: { weekly: boolean (default true), channels: ('IN_APP'|'WHATSAPP')[] }`.
- WhatsApp: when the WhatsApp channel ships (subscription Stage 6 / `REMINDER_CHANNELS`), the same
  report goes out as an approved template. Keep the text builder separate so both channels share it.
- Also expose to the **rep** on delegated catalogs — a rep showing "your menu got 1,240 views" at a
  renewal visit is the best sales tool we have.

## Part D — Mirage-fe: one new event

- Add `menu_item_impression` to the END of `EVENT_TYPES` in **both**
  `mirage-be/src/Models/analyticsEventModel.js` and `mirage-fe/src/analytics/types.ts` (frozen-API rule
  in that file's header). Fire once per item per session when ≥ 50% of the card is visible for
  ≥ 1s (IntersectionObserver in `MenuItemCard.tsx`), batched like every other event.
- Add a scoped aggregation `/me/item-funnel` → per item `{ impressions, opens, arViews }`.

## Part E — Flutter

- `lib/presentation/screens/catalog/weekly_report_screen.dart`: header KPIs with ▲▼ deltas,
  7-day bar chart, top 3 dishes with thumbnails, busiest-hours heat strip (7×24), tips as action
  cards that deep-link to the fix (product editor, publish screen, model generation).
- Report history list (last 12 weeks) from the Catalog analytics screen.
- **Share as image** button: renders the summary card to PNG → share sheet (owners love posting
  "1,000 people saw our menu this week").

## Tests

- Report builder with fixture analytics; delta suppressed below 20 views; IST week boundaries.
- Each insight rule true/false vectors; ranking picks top 2.
- Processor idempotent (run twice → one report, one notification).
- New event accepted by collect endpoint; unknown types still rejected.

## Done when

- [ ] Monday morning, a real test catalog gets a notification with correct numbers (cross-check
      against the existing analytics screen).
- [ ] A tip deep-links to the right screen and the issue it names is real.
- [ ] Turning weekly reports off stops them the next week.
