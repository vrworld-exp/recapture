# Subscription enforcement — rollout runbook (Stage 5)

**What flips:** one boolean, `subscriptionGatesEnabled: true`, on the single `client_configs`
document in Atlas. No deploy. Everything below it is preparation so that the flip takes nothing
dark, and the last line is how to take it back.

**Who:** ops + one engineer on call for the first 24 h. **When:** a weekday morning IST, never a
Friday — restaurants publish in the evening and the sweep's first real pauses land ~7 days after
the first lapses.

Source: [`stage-05-enforcement.md`](stage-05-enforcement.md); product rules in
`RECAPTURE_SUBSCRIPTION_PLAN.md` §5, §6, §8-D, AC-3, AC-4.

---

## The order, and why it is the order

| # | Step | Platform | Done when |
|---|---|---|---|
| 1 | **Deploy Mirage Part B** (`mirage-be`, then `mirage-fe`) and verify `arEnabled` on ONE restaurant with the probe below. | mirage-be host, `mirage-fe` FTP deploy | `PUT … {"arEnabled":false}` → the public page shows photos, no `<model-viewer>`, no AR button; `true` → 3D is back. Same URL throughout. |
| 2 | **Deploy the ReCapture backend** with the flag ABSENT. Keep the instance awake. | Render → Deploy; Render → Cron (or `utils/axiosBackendMakeAlive.ts`) | The worker log shows `[subscription-sweep] to_grace=0 to_paused=0 …` every 10 min (`SUBSCRIPTION_SWEEP_INTERVAL_MS`) and `[analytics] subscription_sweep_ran` beside it. |
| 3 | **Grandfather** every catalog that is already live: dry run, read the list, then the real run. | Your machine, prod `MONGODB_URI` in `.env` (never commit it) | `npx tsx scripts/grandfather-catalogs-comped.ts --dry-run` lists what it would comp; the real run reports `comped` = that count and `skipped` = rows that already existed. Safe to re-run. |
| 4 | **Flip the flag:** `db.client_configs.updateOne({}, { $set: { subscriptionGatesEnabled: true } })`. | Atlas → Browse collections → `client_configs` | `GET /catalog/publish/status` for a catalog with no row now lists `SUBSCRIPTION_REQUIRED`; a comped one lists nothing new. |
| 5 | **Watch for 24 h.** | Render → Logs; analytics sink | `publish_blocked_by_subscription` counts are explainable (reps starting trials, not paying customers being refused); `subscription_state_changed` only names catalogs you expect; no `ENTITLEMENT_FAILED` admin alerts. |
| 6 | **Rollback, if needed:** `{ $set: { subscriptionGatesEnabled: false } }`. | Atlas | Gates are off on the next request. The sweep keeps running harmlessly — it moves rows, enqueues jobs, and Mirage keeps serving whatever `arEnabled` says; **nothing is deleted or unpublished by any of it.** Re-flip when ready. |

Step 1 before step 2 is the one ordering that matters: the pause job writes a field
(`arEnabled`) that an old Mirage would ignore silently — customers would keep seeing 3D on a
paused restaurant, which is harmless but wrong, and nothing would tell you.

Step 3 before step 4: a live catalog with no row gets `SUBSCRIPTION_REQUIRED` on its next
publish the moment the flag is on. The grandfather comp is what stops that. A catalog the script
skipped because it was never provisioned has nothing live to lose; its first publish shows the
gate and the rep starts a trial (that is the designed path).

---

## The Mirage probe (step 1)

```bash
MIRAGE=https://<mirage-be host>/api/v1
# 1. pause
curl -X PUT "$MIRAGE/update-restaurant/<restaurantId>" \
  -H "apikey: $MIRAGE_API_KEY" -H "token: $MIRAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d '{"arEnabled":false}'
curl -s "$MIRAGE/get-data-for-new-ui/<slug>" | jq .restaurantData.arEnabled   # → false
#    open the page on a phone: photos only, every dish still listed with its price,
#    a dish that has a model but no photo shows the placeholder card.
# 2. resume
curl -X PUT "$MIRAGE/update-restaurant/<restaurantId>" … -d '{"arEnabled":true}'
curl -s "$MIRAGE/get-data-for-new-ui/<slug>" | jq .restaurantData.arEnabled   # → true
#    reload: 3D is back on the same items, nothing was re-created.
```

`mirage-be/scripts/verify-ar-entitlement.js live` does the same round trip and checks the
response shapes; record its output in the deploy PR.

---

## Keeping the worker awake (E17)

The sweep and the payment reconciler run inside the worker loop, and the loop only runs while the
Render instance is awake. An instance that sleeps pauses nobody and reconciles nothing until the
next HTTP request wakes it. That is the **safe** direction — late, never early — but a restaurant
whose grace ended at 03:00 should not wait until the first scan at 11:00 to pause. Either:

- a Render cron (or any uptime pinger) hitting `GET /health` every 5 minutes, or
- `utils/axiosBackendMakeAlive.ts`, already in the repo, from another always-on process.

Confirm in step 2 by watching the sweep log line arrive on schedule overnight.

---

## What each log line means

| Line | Meaning | Action |
|---|---|---|
| `[subscription-sweep] to_grace=N …` | N rows lapsed into GRACE this pass. Owners got the in-app "has ended / overdue" reminder. | None. Expect N to be small and to match `subscription_state_changed … to: 'GRACE'`. |
| `… to_paused=N pauses_enqueued=N` | N rows paused; N jobs queued. | None. If `pauses_enqueued < to_paused`, the queue write failed — open each catalog on the admin panel and press **Resync 3D**. |
| `Entitlement synced to Mirage` (worker) | The job landed; `arEntitlementSyncedAt` moved. | None. |
| `Entitlement job: row changed since enqueue — skipping (D4)` | The owner paid between the pause and the job. The payment's own resume job is the one that counts. | None. |
| `[subscription-alert] ENTITLEMENT_FAILED …` + an admin bell | A job exhausted its retries, or Mirage refused it. For a **pause** the customer page keeps 3D a while longer (safe). For a **resume** a paid owner has no 3D. | Open the catalog → **Resync 3D**. If it fails again, Mirage itself is down or the credential is wrong — check `PUBLISH_AUTH_REJECTED` in the same log. |
| `[promotion] publish not enqueued … (BLOCKED)` | A 3D model finished for a paused / over-cap restaurant. The owner has a bell notification saying so. | None. |

---

## Rehearsal on staging (do this once before step 4)

One real restaurant on staging, with the flag on:

1. Start a trial from the rep app; publish; scan the QR → 3D loads.
2. In Atlas, set the row's `periodEnd` to now − 1 min. Wait one sweep → `to_grace=1`; the owner's
   bell shows "Your free trial has ended"; the catalog screen shows the red banner; the publish
   screen shows the grace banner; publishing still works.
3. Set `graceEndsAt` to now − 1 min. Wait one sweep → `to_paused=1`; within a minute the worker
   logs `Entitlement synced`; scan the QR → **photo menu loads, no 3D, same URL**. The catalog
   screen shows the paused card first. A 3D publish is refused with `SUBSCRIPTION_REQUIRED`; a
   photo-only one goes through.
4. Pay with a test key from the owner app → ACTIVE; within a minute `Entitlement synced` again;
   scan → 3D is back. The admin panel's "3D sync" line shows the new time.
5. Set the flag back to `false` and confirm a no-row catalog publishes again.

If any line of that is not what you see, do not proceed to step 4.
