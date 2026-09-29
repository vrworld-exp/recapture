# Stage 12 — Google reviews, customer opt-in list, delivery & booking links

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 7.3 (engagement block) — this stage extends it.
**Size:** M

---

## 12.1 More Google reviews

Stage 7.3 adds a "Rate us" button. This stage makes it actually produce reviews.

- **Prompt timing** (Mirage-fe): show a small bottom card "Enjoyed your meal? ⭐ Review us on Google"
  when **either** the visitor has been on the page ≥ 15 min, **or** used "Show to waiter" (Stage 11)
  and returns to the page ≥ 20 min later. Once per visitor per 30 days (localStorage).
- ⚠ **Policy rule — do not gate reviews.** Google's review policy forbids asking only happy
  customers or routing unhappy ones away. So: **no** "rate 1–5 first, then only 4–5 go to Google".
  Every customer gets the same Google button. A separate, always-visible "Private feedback to the
  owner" link (7.3 feedback form) is fine as long as it isn't a filter in front of Google.
- **Review link helper** (Flutter): the owner pastes their Google Maps business link or searches
  their business name; we build the `https://search.google.com/local/writereview?placeid=…` link.
  Store as `engagement.reviewUrl` (validated `https://` + google domain or `g.page`).
- Analytics: `review_prompt_shown`, `review_click` → weekly report line "23 customers tapped Review".

## 12.2 Customer opt-in list ("Get offers on WhatsApp")

Owners want their own customer list for birthday and festival offers. Build it **consent-first**
(India's DPDP Act 2023: clear notice, specific purpose, easy withdrawal).

- **Mirage-fe**: optional card (owner toggles `customers.optInEnabled`): "Get special offers from
  Café Mocha on WhatsApp" → name (optional), phone (required, +91 validation), birthday
  (optional, day+month only), checkbox **unticked by default**: "I agree to receive offers from
  Café Mocha. I can opt out anytime." with a link to a short notice page. No pre-ticked boxes, no
  forced opt-in to see the menu.
- **Mirage-be**: `POST /public/opt-in` → rate-limited per IP + visitor, dedupe by
  `(restaurant, phone)`, stores `{ restaurant, phone, name?, birthday?, consentText, consentAt, source: 'menu', optedOutAt? }`.
  Store the exact consent text version shown. Relay to ReCapture via a signed webhook or let
  ReCapture pull (`GET /admin/opt-ins?since=`), matching how analytics are proxied today.
- **ReCapture**: `CustomerContact` model per catalog; owner screen "Customers" with count, list,
  search, export CSV (owner only, audit-logged), delete one, and **opt-out** handling: a
  customer replying STOP / tapping the unsubscribe link sets `optedOutAt` and they are excluded
  from every export and send.
- **Sending** is **out of scope** for this stage: we give the owner the list and a "Copy message"
  helper; bulk WhatsApp sending needs WhatsApp Business API templates, cost per message, and
  opt-out plumbing — separate design (ties into the WhatsApp channel of subscription Stage 6).
- Birthday helper: "3 customers have a birthday this week" card in ReCapture.
- Data retention: auto-delete contacts with no activity for 24 months; delete all on catalog deletion.

## 12.3 Delivery & booking links

- `Catalog.links: { zomato?, swiggy?, magicpin?, eazydiner?, dineout?, booking?: { type: 'WHATSAPP'|'PHONE'|'URL'; value } }`.
- Validate host per platform (`zomato.com`, `swiggy.com`…), https only.
- **Mirage-fe**: "Order online" row with platform logos in the contact sheet (`BusinessLinks.tsx`)
  and optionally in the header; "Book a table" button → WhatsApp prefilled "Hi, I'd like to book a
  table for __ people on __ at __", or phone call, or URL.
- Analytics: `delivery_link_clicked { platform }`, `booking_clicked`.
- Mirage-be: `links` object (merge), projected publicly. Sync in `syncCatalogBranding()`.

## Tests

- Review prompt timing + frequency cap; no rating gate exists anywhere in the flow.
- Opt-in validation, dedupe, rate limit, opted-out excluded from export, consent text stored.
- Link host validation.

## Done when

- [ ] Review button opens the restaurant's Google "write a review" box directly.
- [ ] A customer opts in from the menu; owner sees them in ReCapture; opt-out removes them from export.
- [ ] Zomato/Swiggy logos appear only for platforms the owner filled in.
