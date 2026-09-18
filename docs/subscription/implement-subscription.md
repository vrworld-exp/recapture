# Implement Subscription — the run order and the manual work

The single checklist for shipping the subscription layer end to end. The coding prompts in this
folder do the code; **this file is everything around them** — which prompt to run when, what to
do by hand, on which platform, and how you know each step worked.

Legend: 🤖 = paste a prompt into Claude Code · 👤 = you do it by hand · ✅ = a check before moving on

---

## 0. Before the first prompt (decisions + accounts) — Day 0

These have lead times. Start them **before** any code, in parallel.

| # | Who | Platform | Do this | Why now |
|---|---|---|---|---|
| 0.1 | 👤 Founder | **Razorpay Dashboard** (dashboard.razorpay.com) | Create the account, complete **KYC** (PAN, bank account, business proof). Until KYC clears you only get `rzp_test_` keys. | KYC takes 2–7 working days; Stage 3 needs live keys to go to production. |
| 0.2 | 👤 Product | This folder | Answer the three open items in [`gaps-addendum.md`](gaps-addendum.md): **G7** owner cancel (recommended: none), **G9** upgrade = fresh full-price period (recommended: yes), **G8** who owns the marketing pricing page. | G9 changes Stage 3 Part B copy; G7 changes Stage 4 scope. |
| 0.3 | 👤 Product | Plan §13 item 5 | Pick the yearly display rounding (recommended: nearest rupee). | Stage 2 screen renders it. |
| 0.4 | 👤 Founder | SMS vendor (**MSG91** or **Twilio**; none is wired today — `providers/sms.ts` is a stub) | Decide whether the Stage 4 nudge ships on the stub (in-app bell only) or on a real vendor. If real: create the account, get DLT-registered sender id + template approval (India, TRAI DLT — takes ~1 week). | The stub is fine for launch; only the automated reminders (Stage 6) truly need a vendor. |
| 0.5 | 👤 Legal/Founder | Terms page (marketing site or a static page under `mirage.mayasabhaxr.com`) | Publish the terms text: prepaid periods, **non-refundable except accidental duplicate payment**, no GST charged. Razorpay checkout needs a URL for terms and refund policy on the live account. | Stage 3 Part B links to it from the consent sheet. |
| 0.6 | 👤 Ops | **MongoDB Atlas** | Note the `client_configs` collection on the production cluster — you will edit its single document twice (Stage 1 flag stays absent; Stage 5 sets it `true`). | No deploy is needed to flip; know where the switch is. |

✅ Gate 0: Razorpay KYC submitted; G7/G9 answered in writing (edit `gaps-addendum.md` § "Not buildable here" with the decision); terms URL exists (even as a draft page).

---

## 1. How to run a prompt (same recipe every stage)

1. `cd "d:/ASHISH_K3/VR World Code 2/phase2/ReCapture"` — open Claude Code **at the ReCapture root** (it reads `AGENTS.md`/`CLAUDE.md` automatically). For Stage 5 Part B open it at `phase2/mirage-be` and `phase2/mirage-fe` instead.
2. `git checkout -b feat/subscription-stage-NN` from `main`.
3. Paste the whole stage file (or Part A / Part B for the split stages) as the prompt. Prefix
   with one line: *"Implement this prompt. Defer to AGENTS.md on any conflict. Run the test
   suite once at the end, not per change."*
4. When it finishes: read the **Acceptance Criteria** section of the prompt and tick each one
   yourself — do not take the agent's word for it.
5. `cd recapture-api && npx tsc --noEmit && npm run lint && npm test`; root: `flutter analyze && flutter test`.
6. Optional: `/code-review` on the branch, then `/simplify`.
7. PR → merge to `main` → Render auto-deploys the backend; CI pushes the Android **Internal
   testing** track (see §3.5).

---

## 2. The run order

| Step | Kind | What | Platform / place | Depends on |
|---|---|---|---|---|
| 1 | 🤖 | [`stage-01-foundations.md`](stage-01-foundations.md) | Claude Code @ ReCapture | Gate 0 |
| 1a | 👤 | Merge + deploy backend. **Do not** create the `subscriptionGatesEnabled` key. Confirm `/health` and one publish still work in production. | Render (recapture-api) | 1 |
| 2 | 🤖 | [`stage-02-trial-and-status.md`](stage-02-trial-and-status.md) | Claude Code @ ReCapture | 1a |
| 2a | 👤 | Deploy backend; release the app to Internal testing; on a test rep account start a trial on a test restaurant and see the chip. | Render, Google Play Console (Internal testing) | 2 |
| 3-pre | 👤 | Razorpay **test mode**: Settings → API Keys → generate `rzp_test_` key + secret. Settings → Webhooks → add `https://<render-host>/webhooks/razorpay`, secret of your choosing, events: `payment.captured`, `order.paid`, `payment.dispute.created`, `payment.dispute.closed`. | Razorpay Dashboard | 0.1 |
| 3-env | 👤 | Add `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET` (`sync: false`) to `render.yaml` **and** set their values in the Render service → Environment. Use **test** keys on the staging service; leave them absent on production until 3c. | Render → recapture-api → Environment | 3-pre |
| 3A | 🤖 | [`stage-03-payments.md`](stage-03-payments.md) **Part A** | Claude Code @ ReCapture | 2a, 3-env |
| 3a | 👤 | Deploy to staging. `curl` an order; pay it on Razorpay's test checkout; check the webhook log in the dashboard shows `200`; Atlas shows the subscription `ACTIVE`. | Render, Razorpay Dashboard → Webhooks → logs, MongoDB Atlas | 3A |
| 3B | 🤖 | [`stage-03-payments.md`](stage-03-payments.md) **Part B** | Claude Code @ ReCapture | 3a |
| 3b | 👤 | Internal testing build; on a real Android phone pay with test UPI `success@razorpay`; owner screen flips to Active without leaving the app. | Google Play Console, a physical Android device | 3B |
| A | 🤖 | [`gaps-addendum.md`](gaps-addendum.md) **Prompt A** (disputes, standees, receipt, admin alerts, copy) | Claude Code @ ReCapture | 3b |
| 3-cap | 👤 | Razorpay → Settings → **Payment capture** → auto-capture **ON** (otherwise payments sit "authorized", never "captured", and are auto-refunded after 5 days — E6). | Razorpay Dashboard | 3-pre |
| 4 | 🤖 | [`stage-04-rep-tools.md`](stage-04-rep-tools.md) | Claude Code @ ReCapture | 2a (can run in parallel with 3) |
| 4a | 👤 | If a real SMS vendor was chosen in 0.4: wire it into `sendTemplatedSms` (a one-file change; ask the agent), add its env keys to Render. Otherwise skip — the in-app bell delivers the nudge. | Render, MSG91/Twilio console | 4 |
| 5B | 🤖 | [`stage-05-enforcement.md`](stage-05-enforcement.md) **Part B** (Mirage) | Claude Code @ `mirage-be`, then @ `mirage-fe` | — (independent; do it early) |
| 5b | 👤 | Deploy **mirage-be** to wherever it is hosted today; push `mirage-fe` `production` branch → GitHub Actions FTP-deploys `dist/` to `mirage.mayasabhaxr.com`. Run the Part B **probe** (`PUT update-restaurant {arEnabled:false}` → page shows photos only → set `true`). | mirage-be host, GitHub Actions (mirage-fe), a phone on the public URL | 5B |
| 5A | 🤖 | [`stage-05-enforcement.md`](stage-05-enforcement.md) **Part A** | Claude Code @ ReCapture | 3A, 5b |
| 5a | 👤 | Deploy backend (flag still absent). Confirm the worker log shows `subscription_sweep_ran` every 10 min with zeros. **Keep the instance awake** (Render cron / `axiosBackendMakeAlive`) — a sleeping instance runs no sweep and no reconcile (E17). | Render → Logs, Render → Cron | 5A |
| B | 🤖 | [`edge-cases-hardening.md`](edge-cases-hardening.md) **Prompt B** (grace copy, early-renewal warning, PAUSED_90D, cash refund row) | Claude Code @ ReCapture | A, 5A |
| 5c | 👤 | **Go live on Razorpay:** KYC approved → Settings → API Keys → generate **live** keys; Webhooks → add the same URL/events in **live** mode. Set `rzp_live_` values on the **production** Render service. Boot refuses if `NODE_ENV=production` gets a test key (B8) — that is the check working. | Razorpay Dashboard (live mode), Render production Environment | 0.1 approved |
| 5d | 👤 | **Production app release:** promote the Internal-testing build (contains Stages 2–4, A, 5A UI) to **Production** on Play. Wait for rollout to reach existing installs (≥ 48 h) **before** flipping the flag — an old app cannot render the new gate rows' Fix buttons. | Google Play Console → Production | 3b, 4, 5a |
| 5e | 👤 | Grandfather: `cd recapture-api && npx tsx scripts/grandfather-catalogs-comped.ts --dry-run` against production `MONGODB_URI`, read the list, then run without `--dry-run`. | Your machine with the prod URI in `.env` (never commit it) | 5a |
| 5f | 👤 | **Flip the switch:** Atlas → `client_configs` → the one document → add `subscriptionGatesEnabled: true`. No deploy. | MongoDB Atlas | 5c, 5d, 5e, G8 done |
| 5g | 👤 | Watch for 24 h: `publish_blocked_by_subscription` in the Render logs (analytics is console in non-prod — in prod check whatever sink is wired, else logs), Razorpay payments page, admin bell for alerts. | Render Logs, Razorpay Dashboard | 5f |

✅ Gate after each 🤖 step: the prompt's Acceptance Criteria are all ticked and `npm test` / `flutter test` are green on **your** machine.

---

## 3. Manual work, grouped by platform

### 3.1 Razorpay Dashboard
- **Day 0:** account + KYC (bank, PAN, business proof). Fill "Business website" with `mirage.mayasabhaxr.com` and the terms/refund-policy URL from 0.5.
- **Test mode (before Stage 3):** API keys; webhook URL `https://<staging-host>/webhooks/razorpay`; events `payment.captured`, `order.paid`, `payment.dispute.created`, `payment.dispute.closed`; choose a webhook secret (any long random string — it is *your* `RAZORPAY_WEBHOOK_SECRET`).
- **Live mode (Stage 5c):** repeat keys + webhook for the production host. Toggle "Test mode" off in the dashboard header to see live keys.
- **Checkout settings:** enable UPI, cards, net banking; disable EMI/pay-later/wallets you do not want; set the brand name and logo shown in the sheet.
- **Settings → Payment capture:** auto-capture **ON** (E6).
- **After launch:** Payments → check settlements land in the bank (T+2/T+3); Disputes tab is where B9 cases appear.
- **If the admin bell says `WEBHOOKS_SILENT`:** Settings → Webhooks → the webhook was auto-disabled after repeated failures — fix the server first, then re-enable it (E4). Payments were still recorded by reconciliation; nothing is lost.

### 3.2 Render (recapture-api)
- Add to `render.yaml` (`sync: false`) and set in Environment: `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`. Optional tunables with defaults: `SUBSCRIPTION_ORDER_RECONCILE_INTERVAL_MS`, `SUBSCRIPTION_SWEEP_INTERVAL_MS`, `SUBSCRIPTION_NUDGE_MAX_PER_WINDOW`, `SUBSCRIPTION_NUDGE_WINDOW_SECONDS`.
- Staging service gets **test** keys; production gets **live** keys; never the same values on both.
- The worker: confirm `RUN_WORKER_IN_PROCESS` is what production uses today; the sweep and reconcile ticks run inside that loop, so a worker that is off means no pauses and no reconciliation.
- **Sleep:** a Render instance that spins down runs no sweep and no reconcile until an HTTP request wakes it. Add a Render **Cron Job** (or any external ping) hitting `/health` every 10 min, or use the existing `axiosBackendMakeAlive` util (E17).
- Logs: search `subscription_sweep_ran`, `razorpay_webhook_rejected`, `subscription_payment_recorded`.

### 3.3 MongoDB Atlas
- `client_configs` (one document): **Stage 1–5a leave it alone**; **Stage 5f** add `subscriptionGatesEnabled: true`. Optional: `subscriptionPlans` object to override prices without a deploy (must pass the schema or defaults are served — check the Render log for the warning).
- New collections appear automatically: `catalogsubscriptions`, `paymentrecords`. Take a **snapshot/backup** before 5e and before 5f.
- Rollback switch: set `subscriptionGatesEnabled: false`. Gates off instantly; sweeps continue harmlessly; nothing is deleted.

### 3.4 GitHub
- One PR per stage from `feat/subscription-stage-NN`; merge to `main` triggers Render deploy + the Android internal lane.
- Add `PLAY_STORE_JSON_KEY` etc. already exist for CI; nothing new. For `mirage-fe`, push to `production` branch triggers the FTP deploy.
- Never commit `.env` with the prod `MONGODB_URI` used in 5e.

### 3.5 Google Play Console (and App Store Connect)
- Stages 2, 3B, 4, A, 5A UI each ride the CI **Internal testing** track automatically.
- **Before 5f:** promote to **Production** and wait for the rollout; the gate rows exist in the app since Stage 1 but their Fix buttons only since Stage 2.
- `razorpay_flutter` adds no new Play permissions; if the review asks about payments, it is "sale of a service to businesses via a third-party processor" (not in-app digital goods — Google Play Billing does not apply).
- iOS: CI is a disabled stub (AGENTS.md §0.10). If iOS ships later, Apple's rule is the same (a business service, not digital content) — but a reviewer may ask; keep the terms URL handy.

### 3.6 Mirage (mirage-be host + mirage-fe FTP)
- Deploy Stage 5 Part B **before** Stage 5 Part A goes live: the pause job writes `arEnabled`, and an old Mirage would ignore it silently (customers would keep seeing 3D — harmless but wrong).
- `mirage-fe`: push `production` → GitHub Actions → FTP to `/mirage.mayasabhaxr.com/`. Clear any CDN/browser cache used for the public page if one exists.
- Run the probe on one real restaurant and screenshot both states for the PR.

### 3.7 Marketing site (G8)
- Update the pricing page: Taste **10**, Signature **15**, MasterChef **30** complimentary QR standees; monthly prices ₹1,199 / ₹1,799 / ₹2,499; "save 30% yearly". Remove any per-photo/per-3D wording. Do this **before 5f**.

### 3.8 Sales team (no platform)
- Hand out plan §14 (the one-page summary) the day the flag flips.
- Rep field rule: never pay with your own UPI; cash → "Record cash payment" → an admin verifies.
- Tell reps that every new restaurant now needs **Start trial** before its first publish.

---

## 4. Verification gates (do not skip)

| After | Check | Where |
|---|---|---|
| 1a | Publish an existing catalog in production — identical behaviour to before. | App |
| 2a | Trial started by a rep shows on the owner's Subscription screen; a second trial attempt is refused. | App (rep + owner accounts) |
| 3a | Test payment → webhook log `200` → Atlas row `ACTIVE`, `periodStart` = payment time. Replay the webhook from the dashboard → nothing changes. | Razorpay Dashboard, Atlas |
| 3b | On a real phone: the Razorpay sheet opens inside the app; success → "activating…" → Active. | Android device |
| 5b | Public page with `arEnabled:false`: photos only, no AR button, placeholder for photo-less 3D dish, item-view analytics still counted. | Phone on public URL, Mirage admin analytics |
| 5a | Worker log shows the sweep tick; set one staging subscription's `periodEnd` to the past → next tick moves it to GRACE with `graceEndsAt` = +7 d. | Render logs, Atlas |
| 5f | New restaurant with no trial → Publish shows "Subscription needed" with a working Fix; rep starts trial → publish succeeds. | App |

---

## 5. Rollback

| Symptom | Action | Platform |
|---|---|---|
| Publishes wrongly blocked | `subscriptionGatesEnabled: false` | Atlas |
| 3D wrongly hidden on a restaurant | Admin → `resync-ar`, or `PUT update-restaurant {arEnabled:true}` directly | App admin / Mirage admin API |
| Webhook failures piling up | Nothing is lost — reconciliation picks paid orders up within 5 min once the endpoint is healthy; check the signature secret matches on both sides | Render env, Razorpay webhook settings |
| Wrong keys on a service | Fix the env var; the server refuses to boot on a live/test mismatch, which is the safety net working | Render |
| Bad price override | Delete `subscriptionPlans` from the config doc → defaults served instantly | Atlas |







Ai res --------------------------->>>>>>>


Written for: you (the person driving the rollout) and the sales/ops people who own the manual steps.

Created implement-subscription.md and made it the "start here" link in the README. It has six parts:

Day 0 (before any code) — the long-lead-time items: Razorpay KYC (2–7 working days), the G7/G9/G8 decisions, yearly rounding, SMS vendor choice (MSG91/Twilio, or stay on the stub), terms/refund-policy page, and locating the client_configs doc in Atlas.
How to run a prompt — the same 7-step recipe for every stage (branch, paste, tick the AC yourself, run tests once, PR).
The run order — a 22-row table interleaving 🤖 prompt runs with 👤 manual steps, each with its platform: Stage 1 → deploy → Stage 2 → Razorpay test keys + webhook → Render env → 3A → staging payment probe → 3B → phone test → Gap Prompt A → Stage 4 → Mirage Part B first → mirage-be/mirage-fe FTP deploy + probe → 5A → live Razorpay keys → Play Production rollout (wait ≥48 h so old apps can't hit the new gate) → grandfather script → flip subscriptionGatesEnabled: true in Atlas → 24 h watch.
Manual work grouped by platform — Razorpay Dashboard, Render, MongoDB Atlas, GitHub, Google Play Console (+ the note that Play Billing doesn't apply to a business service), Mirage host + FTP, marketing site, and a short sales-team handout.
Verification gates — one concrete check after each deploy, with where to look.
Rollback — five symptoms → action → platform, led by the no-deploy flag flip.
Two things I stated as facts from the repos that you should confirm match reality: mirage-fe deploys over FTP via GitHub Actions on the production branch (from its AGENTS.md), and I could not find where mirage-be is hosted — the file says "wherever it is hosted today", so fill that in.
















Text gen by ai ---------------------------------------->>>>>>>

HOW TO USE THESE PROMPTS (simple version)

What you have
- 5 stage files (stage-01 to stage-05) and 1 extra file (gaps-addendum.md).
- Each file is a ready-made instruction for Claude Code. You do not write any code yourself.
- Stage 3 and stage 5 have two halves inside: Part A and Part B. Treat each half as its own prompt.

------------------- The order ----------------------------
1. stage-01-foundations.md
2. stage-02-trial-and-status.md
3. stage-03-payments.md  -> Part A first, then Part B
4. gaps-addendum.md      -> only the section called "Prompt A"
5. stage-04-rep-tools.md (can be done any time after stage 2)
6. stage-05-enforcement.md -> Part B first (this one is for the Mirage folders), then Part A
7. edge-cases-hardening.md -> only the section called "Prompt B" (small; do it after 4 and 6)

Doing one prompt (repeat this for every file)
1. Open a terminal in the ReCapture folder and start Claude Code.
   For stage-05 Part B, open it in the mirage-be folder, run it, then again in the mirage-fe folder.
2. Make a new git branch, for example: feat/subscription-stage-01
3. Open the stage file, copy the WHOLE file (for a split stage, copy only Part A or only Part B).
4. Paste it into Claude Code. Before the pasted text add this one line:
   "Implement this prompt. Defer to AGENTS.md on any conflict. Run the tests once at the end."
5. Wait for it to finish. It may ask a question - answer it.
6. Scroll to the "Acceptance Criteria" list at the bottom of the prompt and check each line
   yourself. If something is not done, tell Claude Code exactly which line is missing.
7. Run the checks on your machine:
   - in recapture-api:  npx tsc --noEmit   then   npm run lint   then   npm test
   - in the ReCapture root:  flutter analyze   then   flutter test
   All must pass before you continue.
8. Commit, push, open a pull request, merge to main.
9. Do the manual step that follows that stage in the table in section 2 above
   (Render deploy, Razorpay keys, Play Store build, Atlas flag, and so on).
10. Only then start the next file.

Rules of thumb
- Never run two stages at the same time on the same branch.
- Never skip the manual step between stages; the next prompt assumes it happened.
- The switch that turns the feature on for real customers is one field in MongoDB Atlas:
  subscriptionGatesEnabled: true  in the client_configs document. Do not set it until
  step 5f in the table above. To turn everything off again, set it to false.
- If a prompt says "Assumptions" at the end, read them. If any assumption is wrong for you,
  change that line in the file BEFORE pasting it.
- Keep every stage file unchanged otherwise; they reference each other by name.

If something goes wrong in the middle of a prompt
- Ask Claude Code to "show me what you changed so far" and read it.
- If it went off track, discard the branch (git checkout main, delete the branch) and paste
  the same prompt again in a fresh session. The prompts are written to be re-runnable.
