# Stage 4 — Opening hours, announcement strip, time-windowed categories

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 2.
**Size:** M
**Time rule (README D7):** all "is it now?" checks run in the browser in the restaurant's
`timezone` (default `Asia/Kolkata`), using `Intl.DateTimeFormat` — never the phone's own zone.

---

## 4.1 Opening hours + "Open now" badge

- **ReCapture model** `Catalog.hours`:

  ```ts
  interface CatalogHours {
    timezone: string;                           // IANA, default 'Asia/Kolkata'
    weekly: { day: 0|1|2|3|4|5|6; open: string; close: string }[]; // 'HH:mm', close < open = past midnight
    closedDates?: string[];                     // 'YYYY-MM-DD' holidays
    showOpenBadge: boolean;
  }
  ```

  Multiple rows per day allowed (lunch + dinner). Validation: `HH:mm`, max 3 slots/day, no
  overlap, ≤ 60 closed dates in the future.
- **Mirage-be**: `hours` object on `restaurantModel.js` (`parseObjectField`, **replace** not
  merge — a partial weekly list is meaningless), projected publicly.
- **Mirage-fe**: `src/features/menu/hours.ts` pure `isOpenAt(hours, date)` + `nextChange()`;
  header chip "Open · closes 11 pm" / "Closed · opens 12 pm"; full week table in the contact
  sheet (`BusinessLinks.tsx`). Menu stays fully browsable when closed — it's a badge, not a gate.
- **Flutter**: "Opening hours" section on the business profile screen: 7 day rows with add-slot,
  "same as Monday" copy button, holiday date list.

## 4.2 Announcement strip

- **ReCapture** `Catalog.announcement`:
  `{ text: string (≤ 120), emoji?: string, style: 'info'|'offer'|'alert', startsAt?: Date, endsAt?: Date, link?: string }`.
- **Mirage-be** `announcement` object, projected publicly.
- **Mirage-fe**: slim dismissible bar under the header, colour from `--c-primary`/`--c-accent`
  by style, shown only while `startsAt ≤ now < endsAt` (either bound optional). Dismiss is
  remembered per announcement text hash in localStorage (try/catch). Must not collide with
  `PaymentDueBanner` — payment banner wins and the announcement stacks below it.
- **Flutter**: card on catalog screen: text, style chips, optional date range, "Clear". Show
  a "Scheduled" / "Live" / "Expired" label. Note: it goes live on Publish (D6) — but the date
  window then works on its own, which is the point (owner sets Diwali offer once).

## 4.3 Time-windowed categories (breakfast, lunch, happy hour)

- **ReCapture** `CatalogCategory.schedule?: { days: number[]; from: 'HH:mm'; to: 'HH:mm' } | null`
  plus `outsideWindow: 'hide' | 'dim'` (default `dim` — "Available 7–11 am" label, still visible).
- **Mirage-be** `categoryModel.js` `schedule` + `outsideWindow`, included in the category
  projection of the public endpoint.
- **Mirage-fe**: evaluated with the restaurant timezone; `hide` removes the category from the
  pill bar and list; `dim` greys it and shows the window. Re-evaluate every minute while open.
- **Flutter**: "Available at certain times" toggle in `category_manager_screen.dart`.
- Publish worker: carry `schedule` through the category create/update calls.

## Tests

- `isOpenAt` vectors: past-midnight close, two slots, holiday, DST-free zone, day boundary in IST
  vs a phone set to UTC.
- Announcement window: before / during / after, no bounds, dismissed.
- Category schedule hide vs dim.

## Done when

- [ ] Menu at 11:30 pm IST with close 11 pm shows "Closed · opens …" even on a phone in another zone.
- [ ] A scheduled announcement appears and disappears on its dates without a re-publish.
- [ ] Breakfast category dims after 11 am.
