# Subscription go-live checklist

Everything is built and committed on branch `Ashish` (`98001a9` → `ac7528e`, Stages 1–5 + gaps +
hardening). Nothing below needs code. It is **configuration on three sides plus one ops
sequence**, in the order it has to happen. The detailed runbook for the final flip is
[`rollout.md`](rollout.md); the owner-facing flow is [`how-a-user-subscribes.txt`](how-a-user-subscribes.txt).

---

## 1. Razorpay account (first — everything else needs these values)

- [ ] **Activate the account** (KYC / business details) so Live mode is available. Until then use
      `rzp_test_` keys for the staging rehearsal (§5).
- [ ] **Generate API keys** → Dashboard → Settings → API Keys. Copy `Key ID` (`rzp_live_…`) and
      `Key Secret` (shown once).
- [ ] **Create a webhook** → Settings → Webhooks → Add:
  - URL: `https://<recapture-api host>/webhooks/razorpay`
  - Secret: any strong string you make up — it becomes `RAZORPAY_WEBHOOK_SECRET`
  - Events (the ones `services/subscription/webhookService.ts` handles):
    `order.paid`, `payment.captured`, `payment.failed`, `refund.processed`, `refund.failed`,
    `payment.dispute.created`, `payment.dispute.won`, `payment.dispute.lost`,
    `payment.dispute.closed`
- [ ] Webhooks are **per mode** — create one in Test mode too if you rehearse on staging.
- [ ] Nothing to register for the Flutter app. The backend returns `keyId` inside the checkout
      response (`checkoutService.ts`), so the key never lives in an app build.

## 2. Backend — `recapture-api` on Render

- [ ] Env vars (all listed in `recapture-api/.env.example`):

  ```
  RAZORPAY_KEY_ID=rzp_live_xxxx
  RAZORPAY_KEY_SECRET=<secret>
  RAZORPAY_WEBHOOK_SECRET=<the string typed into the Razorpay webhook>
  SUBSCRIPTION_ORDER_RECONCILE_INTERVAL_MS=300000   # optional; default is fine
  SUBSCRIPTION_SWEEP_INTERVAL_MS=600000              # optional; default is fine
  ```

- [ ] The `MIRAGE_*` set is correct (`MIRAGE_BASE_URL`, `MIRAGE_API_KEY`, `MIRAGE_ADMIN_TOKEN`,
      `MIRAGE_PUBLIC_BASE_URL`) — pausing/resuming 3D goes through them.
- [ ] Deploy with the flag **absent** (`subscriptionGatesEnabled` does not exist in
      `client_configs` yet — leave it that way for now).
- [ ] **Keep the instance awake**: Render cron (or any pinger) hitting `GET /health` every 5 min,
      or `utils/axiosBackendMakeAlive.ts` from an always-on process. While Render sleeps the
      sweep and the payment reconciler do not run (rollout.md, E17).
- [ ] Confirm the worker log shows `[subscription-sweep] to_grace=0 to_paused=0 …` every 10 min,
      overnight included.

## 3. Mirage — `mirage-be`, then `mirage-fe` (before the flag, never after)

**What Part B is:** when a restaurant stops paying, ReCapture deletes nothing — it sends Mirage
`arEnabled: false` for that restaurant and Mirage's public menu page switches from 3D/AR to plain
photos. That switch is committed (`mirage-be fc11fe0`, `mirage-fe 406ff74`, both on branch
`feature/same-day-qr-f-phase2`) but is **not on the live Mirage servers yet**. This step puts it
there and proves it works.

**Why before the flag:** the moment ReCapture's sweep pauses a restaurant it sends
`arEnabled:false`. An old Mirage accepts the request, ignores the field and keeps serving 3D —
no error anywhere, so nobody would know.

**Where things run** (from each repo's `.github/workflows/ci-cd-pipeline.yml`):

| Repo | Deploys how | Trigger |
|---|---|---|
| `mirage-be` | GitHub Actions → Railway, service `restaurant-be` | push to `development` (dev env) / `production` (prod env) |
| `mirage-fe` | GitHub Actions → `npm run build` → FTP to cPanel | push to `development` → `mirage.mayasabhaxr.co.in` / `production` → `mirage.mayasabhaxr.com` |

Nothing deploys from the feature branch. The commits must reach `development` (staging), then
`production`. No new env vars on Railway or cPanel — Part B added a schema field, a controller
branch and a card component, nothing configurable.

### 3a. Backend first

- [ ] ```powershell
      cd "D:\ASHISH_K3\VR World Code 2\phase2\mirage-be"
      git checkout development
      git merge feature/same-day-qr-f-phase2
      git push origin development        # → Action deploys to Railway dev
      ```
- [ ] GitHub → Actions tab → the run is green; Railway shows the service restarted.

### 3b. Frontend second

- [ ] ```powershell
      cd "D:\ASHISH_K3\VR World Code 2\phase2\mirage-fe"
      git checkout development
      git merge feature/same-day-qr-f-phase2
      git push origin development        # → builds and FTPs dist/ to mirage.mayasabhaxr.co.in
      ```
- [ ] Action green. (Order inside step 3 matters too: the new frontend reads
      `restaurantData.arEnabled`; against an old backend the field is missing and is treated as
      `true`, so nothing breaks, but the "off" state cannot be tested.)

### 3c. Prove it — the probe (`mirage-be/scripts/verify-ar-entitlement.js`)

- [ ] Offline sanity check, no server needed:
      `node scripts/verify-ar-entitlement.js logic`
- [ ] Live round trip against the deployed dev backend, from your machine:
      ```powershell
      cd "D:\ASHISH_K3\VR World Code 2\phase2\mirage-be"
      $env:MIRAGE_BASE_URL      = "https://restaurant-be-devlopment.up.railway.app/api/v1"
      $env:MIRAGE_API_KEY       = "<Mirage's apikey header value>"
      $env:MIRAGE_TOKEN         = "<an admin JWT>"
      $env:MIRAGE_RESTAURANT_ID = "<Mongo _id of one test restaurant>"
      node scripts/verify-ar-entitlement.js live
      ```
      It does `PUT /update-restaurant/<id> {"arEnabled":false}` → `GET
      /get-data-for-new-ui/<slug>` expects `restaurantData.arEnabled === false` → flips back to
      `true` → reads again, and leaves the restaurant as it found it. Expect `N passed, 0 failed`.
      Save the output for the deploy PR.
      `MIRAGE_API_KEY` is the same value ReCapture's Render env holds; `MIRAGE_TOKEN` is an admin
      JWT (log in to the Mirage admin panel and copy it, or reuse ReCapture's `MIRAGE_ADMIN_TOKEN`).
- [ ] The human half the script cannot do: with the flag set to `false`, open
      `https://mirage.mayasabhaxr.co.in/<slug>` on a phone — every dish listed with its price,
      photos instead of 3D, no AR button, a dish with a model but no photo shows the grey
      "3D unavailable" placeholder card. Set it back to `true`, reload — 3D is back on the same URL,
      nothing re-created.

### 3d. Repeat for production

- [ ] First look at what else would ship: `git log production..development` in both repos
      (`production` may be behind by more than Part B).
- [ ] Both repos: `git checkout production; git merge development; git push origin production`.
- [ ] Run the same `live` probe against prod
      (`https://restaurant-be-production-b2d6.up.railway.app/api/v1`) on one real restaurant —
      the script restores its state. Then step 3 is done; go to §2.

Watch-out: `mirage-fe` gained vitest devDependencies in that commit. CI runs `npm install` and
`tsc -b && vite build`; lint is not in CI (there are ~130 pre-existing lint errors). If the build
step fails, read the log before blaming Part B.

## 4. Frontend — Flutter ReCapture app

- [ ] No env vars, no code. **Ship a build that contains the subscription screens** to Play
      Store / TestFlight / web. `razorpay_flutter` is already in `pubspec.yaml`;
      Android `minSdk = 24` satisfies it.
- [ ] Push this build **before** flipping the flag. Older builds in the field will see the
      `SUBSCRIPTION_REQUIRED` publish blocker with no "See plans" button.

## 5. The flip — ops sequence (details in `rollout.md`)

- [ ] **Rehearse on staging once** with `rzp_test_` keys and the flag on — the 5-step script at
      the bottom of `rollout.md`: trial → force GRACE → force PAUSED (3D gone, photos stay) →
      pay from the owner app → 3D returns → flag off, no-row catalog publishes again.
      If any line is not what you see, stop here.
- [ ] **Grandfather** every already-live catalog, from your machine with the prod
      `MONGODB_URI` in `.env` (never commit it):
      `npx tsx scripts/grandfather-catalogs-comped.ts --dry-run` → read the list →
      run again without `--dry-run`. Safe to re-run. Skipping this blocks every existing
      restaurant on its next publish.
- [ ] **Flip the flag** in Atlas → `client_configs`:
      `db.client_configs.updateOne({}, { $set: { subscriptionGatesEnabled: true } })`. No deploy.
- [ ] Verify: `GET /catalog/publish/status` for a catalog with no row lists
      `SUBSCRIPTION_REQUIRED`; a comped one lists nothing new.
- [ ] **Watch for 24 h** (Render logs + analytics): `publish_blocked_by_subscription` counts are
      explainable, `subscription_state_changed` only names expected catalogs, no
      `ENTITLEMENT_FAILED` admin alerts.
- [ ] Rollback if needed: `{ $set: { subscriptionGatesEnabled: false } }`. Gates are off on the
      next request; nothing is deleted or unpublished by the sweep either way.

Weekday morning IST. Not a Friday.

## Open decisions (none block the flip)

- [ ] The five sign-off boxes in [`edge-cases-hardening.md`](edge-cases-hardening.md)
      (E5 / E11 / E34 / E41 / E46) — built the recommended way, not yet ticked.
- [ ] G7 owner self-cancel, G8 public pricing page, G9 upgrade proration
      ([`gaps-addendum.md`](gaps-addendum.md)) — unanswered; current behaviour is
      admin-only cancel / no pricing page / no proration.
