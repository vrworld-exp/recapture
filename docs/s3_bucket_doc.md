

# The four segments

```
prod / wooden-dining-table_665f1a2b3c4d5e6f70819293 / 6660c4d5e6f708192a3b4c5d /
 │              │                     │                          │
 │              │                     │                          └─ jobId — one capture run
 │              │                     └─ projectId — the real identifier
 │              └─ slug — human label, ≤24 chars, from the project name
 └─ env — dev | staging | prod, from NODE_ENV
```

| Segment | Source | Job |
| --- | --- | --- |
| `{env}` | `s3EnvPrefix()` ← `NODE_ENV` | Keeps dev/staging/prod from ever touching each other's objects |
| `{slug}` | `Project.name`, slugified | Debug only. Nothing reads it. Can be stale, can be empty |
| `{projectId}` | ObjectId hex, 24 ch | The actual identity. Guarantees uniqueness, makes prefix-delete safe |
| `{jobId}` | ObjectId hex, 24 ch | Isolation boundary for one capture — what finalize counts inside |

**The important asymmetry: the slug is decoration, the ids are load-bearing.** If
the slug were wrong or missing tomorrow, nothing breaks. If either id were
missing, deletes and finalize counts break.

---

## Slug examples

| `Project.name` | Slug | Rule at work |
| --- | --- | --- |
| `Wooden Dining Table` | `wooden-dining-table` | lowercase, spaces → `-` |
| `Rahul's Café Chair!` | `rahul-s-cafe-chair` | diacritics folded, punctuation → `-` |
| `2nd Floor Lamp` | `2nd-floor-lamp` | leading digit is fine |
| `Vintage Teak Coffee Table with Brass Inlay` | `vintage-teak-coffee-tabl` | cut at 24 |
| `Big Red Kitchen Cabinet Door` | `big-red-kitchen-cabinet` | cut landed on `-`, so it's re-stripped |
| `🪑` | *(empty)* | nothing survives → falls back, see below |

The emoji case is the one to keep in mind:

```
prod/665f1a2b3c4d5e6f70819293/6660c4d5e6f708192a3b4c5d/
```

No slug, **no dangling `_`**. A key must start its segment with an alphanumeric,
so `_665f…` would be malformed.

---

## A full job, in the raw bucket

`msxr-raw-captures`, private:

```
prod/wooden-dining-table_665f1a2b3c4d5e6f70819293/6660c4d5e6f708192a3b4c5d/
├── capture_manifest.json
├── images/
│   ├── EYE/frame_0001.jpg … frame_0024.jpg
│   ├── TOP/frame_0001.jpg …
│   └── LOW/frame_0001.jpg …
├── model-input/{sessionId}/photo_1.jpg …      ← photos picked for Meshy
└── deleted/images/EYE/frame_0007.jpg          ← soft-deleted, parked not erased
```

One full image key:

```
prod/wooden-dining-table_665f1a2b3c4d5e6f70819293/6660c4d5e6f708192a3b4c5d/images/EYE/frame_0001.jpg
```

---

## Same prefix, artifacts bucket

`msxr-model-artifacts`, behind CloudFront — **byte-identical prefix**, which is
what lets a project delete wipe both buckets with one string:

```
prod/wooden-dining-table_665f1a2b3c4d5e6f70819293/6660c4d5e6f708192a3b4c5d/
└── models/
    ├── 6661aabbccddeeff00112233/     ← first generation
    │   ├── model.glb
    │   ├── model.usdz
    │   └── preview.jpg
    └── 6662bbccddeeff0011223344/     ← regenerate: new folder, first one survives
```

Public URL the client gets:

```
https://d3ap77f0m6kfrr.cloudfront.net/prod/wooden-dining-table_665f.../6660.../models/6661.../model.glb
```

---

## Why a second capture doesn't collide

Same project, user re-captures:

```
prod/wooden-dining-table_665f1a2b3c4d5e6f70819293/6660c4d5e6f708192a3b4c5d/   ← Monday
prod/wooden-dining-table_665f1a2b3c4d5e6f70819293/6671f0a1b2c3d4e5f6a7b8c9/   ← Friday
```

Same project folder, different job folders. Both have their own
`capture_manifest.json` and their own `images/EYE/frame_0001.jpg`. This is
exactly what breaks if `{jobId}` goes away.

---

## What you actually gain

Old way, staring at the console:

```
prod/6650aa.../665f1a.../6660c4.../images/EYE/frame_0012.jpg
```

Three opaque ids. You're querying Mongo before you know what you're looking at.

New way:

```
prod/wooden-dining-table_665f1a.../6660c4.../images/EYE/frame_0012.jpg
```

You know the project on sight, and `665f1a2b3c4d5e6f70819293` still pastes
straight into a Mongo query. That's the trade the whole change is buying —
readability without giving up copy-pasteable ids.

---

