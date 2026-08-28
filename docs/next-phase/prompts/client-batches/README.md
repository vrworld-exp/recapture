# ReCapture Flutter Client Prompts — Batched (F1 … F12)

`../02-recapture-client-prompts.md` split into **six self-contained files of two prompts each**, so
one batch can be handed to one session without carrying the other ten prompts along.

Every batch file repeats, verbatim:

- the **shared context** (repo root, `AGENTS.md` as tie-breaker, the standing facts verified in the
  tree — entities, repositories, notifiers, declared-vs-registered routes, existing screens and
  widgets, theme tokens);
- the **standing platform rules** — every prompt ships Android/iOS **and** Flutter web in the same
  change;
- the **architectural constraints** — Riverpod only, no HTTP in presentation, no parsing in the UI,
  no new packages, existing theme tokens, no raw upstream text, parked features stay parked;
- this **navigation table** and a **batch verification block** (analyze, test, web build, APK build,
  manual two-platform checklist).

The prompt text itself is a **byte-for-byte extract** of the original file — nothing was reworded,
added to, or dropped. The original stays in place as the combined reference.

---

## The six batches

| Batch | Prompts | Subject | Depends on | Priority | Status |
|---|---|---|---|---|---|
| [01](batch-01-product-grid-and-editor.md) | F1 · F2 | Product grid · Product editor | — | Critical · High | ✅ complete |
| [02](batch-02-archive-and-categories.md) | F3 · F4 | Archive/restore/delete · Category manager | F1 | High · High | ✅ complete |
| [03](batch-03-bulk-and-business-profile.md) | F5 · F6 | Bulk selection · Business profile | F1, F3, F4 | Low(V2) · High | ✅ complete |
| [04](batch-04-preview-and-publish.md) | F7 · F8 | Catalog preview · Publish + QR | F1 · backend B4, B5 | Medium · **Critical** | ✅ complete |
| [05](batch-05-analytics-and-feedback.md) | F9 · F10 | Analytics dashboard · Feedback layer | F1, F2, F8 · backend B7 | Low(V2) · High | ✅ complete |
| [06](batch-06-web-parity-and-tests.md) | F11 · F12 | Web parity pass · Test hardening | F1–F10 | **Critical** · High | ✅ complete |

**Current position: all six batches are done** (F1–F12 landed, `f8ac0de`). Nothing in this
folder is left to run — the remaining next-phase work is `../03-mirage-prompts.md` (M1–M5),
which runs in `phase2/mirage-be-phase-2-recap/` and `phase2/mirage-fe/`, not here.

---

## Why the pairs are what they are

The pairing is not just "next two in the list" — each batch is two prompts that share state, share
an idiom, or are the two halves of one user-visible outcome:

| Batch | The thing the pair shares |
|---|---|
| 01 | F2 is reached from an F1 card and must write back into the F1 grid without a refetch. |
| 02 | Both are destructive actions over the F1 grid using the same confirmation modal and the same optimistic-update-with-rollback plumbing. |
| 03 | The last two pre-publish authoring surfaces; independent of each other, so they parallelise. |
| 04 | Preview **is** the pre-flight surface for publish — same gate rules, and the publish checklist deep-links back into preview. |
| 05 | Both are state-defined cross-cutting surfaces; analytics degradation renders through the feedback code table. |
| 06 | F11 finds the platform gaps, F12 nails them shut — the testable-platform-flag provider is an F11 instruction *because* F12 needs it. |

---

## Cut lines, if the schedule slips

Per `../../05-mvp-v1.1-v2-bucketing.md`:

- **MVP:** F1, F8, F10, F11, F12 (plus backend B1–B5 and Mirage M1).
- **V1.1 fast-follow:** F2, F3, F4, F6, F7.
- **V2:** F5, F9.

So within a batch: ship **F6 over F5** (batch 03), **F10 over F9** (batch 05), and treat **both** of
batch 06 as non-optional — the phase ships an APK *and* a web build, and F11/F12 are what prove it.

---

## How to use a batch

1. Open a fresh session at `phase2/ReCapture/`.
2. Paste **one fenced prompt block** — not the whole batch file. One prompt per session; each is
   scoped to one reviewable change. Point the session at the batch file for the shared context above
   it, or paste the shared-context section along with the prompt.
3. Follow the delivery order the batch names (the second prompt usually assumes the first).
4. `ReCapture/AGENTS.md` is the tie-breaker over anything written in a prompt. If they conflict,
   AGENTS.md wins and the conflict is **reported**, not silently resolved.
5. Run the batch verification block before opening a PR — `flutter analyze`, `flutter test`,
   `flutter build web --release` **and** `flutter build apk --release`, plus the manual
   two-platform checklist.

---

## Related

- `../README.md` — the full prompt pack: current-state verification, feature coverage matrix
  (features 1–69), recommended build order across all three tracks.
- `../01-recapture-backend-prompts.md` — B1–B7. **B4 and B5 gate batch 04; B7 gates F9 in batch 05.**
- `../03-mirage-prompts.md` — M1–M5. M1 (URL passthrough) is the highest-value unblock for B3.
- `../02-recapture-client-prompts.md` — the original combined F1–F12 file this folder splits.
