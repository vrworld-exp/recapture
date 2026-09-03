# ReCapture Phase 2 — Feature List and the User's Journey Through It

**Who this is for:** anyone who needs to understand what Phase 2 does without reading code —
product, sales, design, QA, or a new engineer on day one.

**What this document is:** every Phase 2 feature written in the language a business owner would
use, followed by the story of how one person moves through all of them in order, and then the
chains that connect them.

**What this document is not:** an architecture doc. For *how* it is built, read
[`next-phase/03-architecture-proposal.md`](next-phase/03-architecture-proposal.md). For the
engineering feature-to-side mapping, read
[`next-phase/02-feature-to-side-mapping.md`](next-phase/02-feature-to-side-mapping.md).

**New to the project? Start with [`phase-2-intro.txt`](phase-2-intro.txt)** — one page, the whole
idea, no detail. Come back here when you need the specifics.

**Also available as:**

- [`phase-2-user-journey.txt`](phase-2-user-journey.txt) — this same document as plain text, for
  anywhere Markdown does not render.
- [`phase-2-feature-checklist.txt`](phase-2-feature-checklist.txt) — the compact companion. One
  line per feature with a built/limited status, a scorecard, and the four things to say and six
  things not to promise in a demo. For a slide, a QA sheet or a status mail.

---

## The one-sentence version

Phase 1 let a user photograph a physical object and get a 3D model back. **Phase 2 turns those
models into a public, scannable storefront** — the user arranges their products in the app,
presses Publish once, and gets a permanent QR code that any customer can scan to browse the
products in 3D and AR on their own phone.

---

## The person using it

A small business owner — a café, a restaurant, a furniture shop. One phone. Not technical.
They care about three things:

1. Getting their products to look good.
2. A QR code they can print on a sticker, a menu, or a standee.
3. Knowing whether anyone actually scanned it.

Everything below serves one of those three.

---

# Part 1 — The complete feature list

Grouped by what the user is trying to do, not by which codebase built it.

## A. Getting in

| # | Feature | What the user does |
|---|---|---|
| A1 | Phone sign-in | Enters a phone number, gets a one-time code, is in. No password ever. |
| A2 | Stays signed in | Closes the app for a week, reopens it, is still signed in. |
| A3 | Personal profile | Sets a display name and a profile photo. Sees their masked phone number. Can sign out. |

## B. Capturing a product in 3D

This half existed before Phase 2, but Phase 2 is what gives it a purpose. It is listed here
because the user experiences one continuous product, not two phases.

| # | Feature | What the user does |
|---|---|---|
| B1 | Create a capture project | Names the thing they are about to photograph. Picks how thorough the capture is. |
| B2 | **Quick capture** | Walks one circle around the object taking **6 photos**. Roughly a minute. This is the mode a real business uses. |
| B3 | **Full capture** | The thorough photogrammetry flow: **48 photos** across multiple rings, with the app auto-taking shots as they move. For when quality matters more than time. |
| B4 | Live capture coaching | The app refuses blurry, too-dark and unsteady shots as they happen, and tells them to tilt up or down when their angle is wrong. |
| B5 | Review before sending | Sees the grid of what they just shot and can retake any individual photo. |
| B6 | Background upload | Photos upload while they use other apps. Losing signal pauses it; getting signal resumes it. |
| B7 | "We're building it" | A progress screen while the 3D model is generated. They can leave and come back. |
| B8 | Model history | One capture can produce **several** models — the first attempt, any regeneration, and an optimized version. The user sees all of them, not just the newest. |
| B9 | Optimize | One tap shrinks a heavy model so it loads fast on a customer's phone. The small version appears as its own entry beside the original. |
| B10 | 3D and AR preview | Spins the model on screen, and on a supported phone places it in the real room. |

## C. Building the catalog

The heart of Phase 2. Everything here is a **draft** — no customer sees any of it yet.

### C1. The catalog itself

| # | Feature | What the user does |
|---|---|---|
| C1.1 | One catalog per account | Creates it once. Names it. There is no concept of juggling several. |
| C1.2 | Catalog name and logo | Uploads a logo and a cover image. |
| C1.3 | Draft / Published / Offline status | Sees at a glance which of the three states their catalog is in. |
| C1.4 | Delete the catalog | Types the catalog name to confirm. Wipes the public page too. The only action that gives up the QR code. |

### C2. Business profile

| # | Feature | What the user does |
|---|---|---|
| C2.1 | Business name, description, phone, address | Fills in the details that appear as branding on the public page. |
| C2.2 | Email, website, social links | Stores them. **The app says plainly which of these reach the public page and which do not.** |

### C3. Categories

| # | Feature | What the user does |
|---|---|---|
| C3.1 | Create a category | "Starters", "Mains", "Desserts". |
| C3.2 | Rename a category | |
| C3.3 | Delete a category | |
| C3.4 | Drag to reorder | Sets the order sections appear in. |
| C3.5 | Uncategorized | Products with no category land in a default bucket rather than being rejected. |

### C4. Adding products

| # | Feature | What the user does |
|---|---|---|
| C4.1 | **Add from a finished capture** | Picks one of their captures, then picks **exactly which model** from that capture's history. Previews each one before deciding. |
| C4.2 | **Add as a photo only** | Some products never get scanned. A photo, a name and a price is a complete product. No AR for these. |
| C4.3 | Name, price, description | The basics. Price is optional. |
| C4.4 | Category | Files the product under a section. |
| C4.5 | Tags | Free-text labels for their own filtering. |
| C4.6 | In stock / Out of stock | A private flag. The app says so at the point of setting it: this changes their own list, not the public page. |
| C4.7 | Featured | Pushes a best-seller to the front. |
| C4.8 | Automatic thumbnail | 3D products get a preview image generated for them. They upload nothing. |

### C5. Managing products

| # | Feature | What the user does |
|---|---|---|
| C5.1 | Product grid | The screen they live in. Every product as a card with its picture, price and status. |
| C5.2 | Search by name | |
| C5.3 | Filter | By category, by type (3D vs photo), by status. |
| C5.4 | Reorder products | Drags them into the order customers will see. |
| C5.5 | Edit any field | Name, price, description, category, tags, availability, featured. |
| C5.6 | **Change which model a product uses** | Re-points a product at a different model from the same capture, after seeing how it looks. A dedicated screen. |
| C5.7 | Replace the photo | |
| C5.8 | Duplicate a product | For variants. The copy is renamed automatically so it can publish. |
| C5.9 | Archive | Takes a product out of the catalog without destroying it. |
| C5.10 | Restore | Brings an archived product back. |
| C5.11 | Delete permanently | Requires typing the product name. |
| C5.12 | Select several at once | Multi-select mode for archiving, deleting or re-categorising a batch in one go. |

## D. Checking before going live

| # | Feature | What the user does |
|---|---|---|
| D1 | **Preview** | Sees the draft laid out the way a customer will see it, before anyone can. |
| D2 | **Publish checklist** | If something would break, the app lists **every** problem at once — not one, fix, retry, next one. Each row is a plain sentence. |
| D3 | One-tap fixes | Some checklist rows carry the fix beside them, like a suggested new name for a duplicate. |

The checklist speaks like this. These are the real messages:

- *"Add at least one product before publishing."*
- *"Give your catalog a name before publishing."*
- *"'Paneer Tikka' has no 3D model yet."*
- *"'Paneer Tikka' is still generating its preview image. Try again shortly."*
- *"More than one product is called 'Paneer Tikka'. Rename one of them."*
- *"'Paneer Tikka' is filed under a category that is no longer in your catalog. Pick one for it, or move it to Uncategorized."*

## E. Going live

| # | Feature | What the user does |
|---|---|---|
| E1 | **Publish** | One button. One deliberate action. Runs in the background, so the app can be closed. |
| E2 | Live progress | Watches products go green one by one. |
| E3 | **Per-product status** | Every product shows Synced, Pending, Failed or Never published, with a plain-English reason for each failure. |
| E4 | **Retry just the failures** | If 8 of 10 succeeded, retry pushes 2, not 10. |
| E5 | **The QR code** | Generated for them. View it, download it as PNG or PDF, share it. |
| E6 | **The QR never changes** | Rename the catalog, republish fifty times, change every product. The printed sticker keeps working. This is a hard guarantee, not a best effort. |
| E7 | The public link | Copy it, share it, open it. |
| E8 | "Draft changes not yet live" | A badge that appears the moment anything is edited after publishing, and clears on the next successful publish. |
| E9 | Last published time | |
| E10 | Take it offline | Removes the products from the public page but **keeps the QR code working**. Going back live is one Publish away. |
| E11 | Activity history | A log of what was published when, and what failed. |

## F. Seeing what happened

Customers scanning the QR code are measured automatically. The user turned nothing on.

| # | Feature | What the user sees |
|---|---|---|
| F1 | Page views | How many times the catalog was opened. |
| F2 | Sessions and visitors | How many separate people, not just hits. |
| F3 | Product views | Which products got opened. |
| F4 | AR launches | How many customers actually placed a product in their room. |
| F5 | 3D model loads | Whether the models are loading for people. |
| F6 | Contact clicks and searches | Whether anyone tapped the phone number or searched the menu. |
| F7 | Trend over time | A chart by day. |
| F8 | Top products | A ranked table, and whether 3D products beat photo-only ones. |
| F9 | Comparison to the previous period | Not just "340 views" but whether that is up or down. |

## G. The app telling the truth

| # | Feature | What the user experiences |
|---|---|---|
| G1 | Confirmation on every action | A toast after add, edit, archive, delete, publish. |
| G2 | Readable errors | Never a raw technical message from an upstream system. Every failure is translated into a sentence with a next step. |
| G3 | Typed confirmation for destructive actions | Deleting a catalog or a product means typing its name. |
| G4 | Works on phone and in a browser | Android and the web build ship together, feature for feature. |

---

# Part 2 — The journey, start to finish

A café owner, one afternoon.

### 1. Sign in — five seconds

Types a phone number. Types the code that arrives. That is the whole account setup. *(A1)*

### 2. Fills in the business — two minutes

Business name, a line of description, phone number, address. Uploads a logo. *(C2.1, C1.2)*

The app is honest here. The website and Instagram fields are marked as stored-but-not-public, so
they will not wonder later why their Instagram link never appeared. *(C2.2)*

### 3. Photographs the first dish — one minute

Taps the plus button, names it "Paneer Tikka", picks the quick 6-photo capture. *(B1, B2)*

Walks a slow circle around the plate. The app rejects two shots, one blurry and one where they
tilted too far down, and says so as it happens rather than afterwards. They retake both. *(B4)*

Reviews the six photos in a grid. Keeps them. *(B5)*

### 4. Waits — a few minutes

The upload runs in the background while they photograph the next dish. *(B6)*

They repeat steps 3 and 4 six more times. By the end there are seven captures in flight.

### 5. Builds the catalog — ten minutes

Opens the Catalog tab. Creates the catalog and names it after the café. *(C1.1)*

Creates three categories: Starters, Mains, Desserts. *(C3.1)*

For each finished capture they tap **Add product**, choose **3D model**, pick the capture — and
here the app does something worth noticing. Paneer Tikka generated **three** models: the first
attempt, a regeneration after that one came out wrong, and an optimized small version. The user
sees all three side by side, previews each, and picks the one that actually looks like the dish.
*(C4.1, B8)*

Then name, price, category, add. A toast confirms it. *(C4.3, C4.4, G1)*

Two items on the menu are drinks that were never worth scanning. Those get added as
**photo-only** products, just a picture, a name and a price. *(C4.2)*

They mark the signature dish **Featured** and drag it to the top. *(C4.7, C5.4)*

### 6. Checks the work — one minute

Opens **Preview** and scrolls through the catalog exactly as a customer will see it. Notices the
dessert photo is dark, goes back, replaces it. *(D1, C5.7)*

### 7. Publishes — one tap

Presses **Publish**.

The app stops them with a checklist of two rows:

- *"'Masala Chai' has no photo yet."*
- *"More than one product is called 'Lassi'. Rename one of them."*

Both are fixable in place, and the second offers *"Use 'Lassi (2)' and publish"* as a button.
They add the missing photo, take the suggested rename, press Publish again. *(D2, D3)*

It runs in the background. They watch products turn green one at a time. Two fail because the
network dropped mid-upload, and show as **Failed** with a readable reason. They tap **Retry
failed**, which pushes exactly those two. Both go green. *(E1, E2, E3, E4)*

### 8. Gets the QR — thirty seconds

The success screen shows the public link and the QR code. They download the PDF, email it to a
print shop, and open the link on their own phone to check it. *(E5, E7)*

The 3D dishes spin. Tapping AR puts a plate of Paneer Tikka on their actual table.

### 9. Two weeks later — prices change

They edit four prices in the grid. The moment they do, a badge appears at the top:
**"Draft changes not yet live."** *(E8, C5.5)*

The printed standees are already on every table. This is the moment the design pays off. They
press Publish again, only the four changed products are pushed, and **the QR code on every table
keeps working untouched.** *(E6)*

### 10. Three weeks later — checks the numbers

Opens **Analytics**. *(F1 through F9)*

- 340 page views, 210 visitors, up 22% on the previous period.
- Paneer Tikka is the most-viewed product.
- 61 customers launched AR.
- The photo-only drinks sit near the bottom of the table.

They conclude that scanning is worth it, and photograph four more dishes. Back to step 3.

---

# Part 3 — How the features connect

Four chains. Every feature sits on one of them.

### Chain 1 — Physical object to catalog product

```
photograph it  →  3D model generated  →  several models to choose from
                                                   ↓
                                            pick the right one
                                                   ↓
                                            becomes a product
```

The link that matters: **a capture is not a product.** One capture can yield several models, and
the user chooses which one becomes the product. That is why *Model history* (B8) and *Change
model* (C5.6) both exist. They are two views of the same idea, one before the product exists and
one after.

### Chain 2 — Draft to live

```
everything the user edits  →  stays private  →  Preview  →  Publish checklist  →  Publish
```

The rule underneath: **nothing reaches a customer until Publish is pressed.** Editing a live
catalog is safe. There is no way to accidentally break the public page mid-edit, and that is what
makes the whole authoring surface relaxed rather than nerve-racking.

Preview and the checklist are the same idea at two levels. Preview answers *does this look
right?* The checklist answers *will this actually work?* Both run before anything is public.

### Chain 3 — Publish to customer to insight

```
Publish  →  public page  →  QR code  →  customer scans  →  views, AR launches
                                                                   ↓
                                                            Analytics screen
```

The user turns on no tracking. The measurement is a property of having published.

### Chain 4 — The loop

```
Analytics  →  "AR is getting used, photo-only isn't"  →  photograph more dishes
    ↑                                                              ↓
    └────────────── republish, same QR ←── add products ───────────┘
```

This is why the stable QR (E6) is load-bearing rather than a nicety. It is what makes the loop a
loop instead of a one-time launch. A QR that changed on republish would mean reprinting every
standee each time a price moved, and the loop would run exactly once.

### The whole picture

```
   CAPTURE                 AUTHOR                  GO LIVE              LEARN
   ───────                 ──────                  ───────              ─────
   project      ┐
   6 or 48 pics ├──►  models ──► product ──┐
   quality gate ┘      (pick)              │
                                           ├──► catalog ──► preview ──► publish ──► QR
   business profile ────────────────────►  │                  ↑           │          │
   categories ──────────────────────────►  │              checklist       │          │
   photo-only products ─────────────────►  ┘                              ▼          ▼
                                                                    public page  analytics
                                                                          │          │
                                                                          └── customer scans
```

---

# Part 4 — The four promises the user can feel

The design guarantees, stated the way a user would state them.

1. **"Nothing I do is live until I press Publish."**
   Editing is always safe. The public page is a snapshot of the last publish, not a live mirror.

2. **"My QR code will never stop working."**
   Not on rename, not on republish, not on taking the catalog offline. The single exception is
   deleting the catalog outright, which is the one action where giving up the link is the point,
   and it demands typing the catalog name to confirm.

3. **"If publishing half-works, I will know exactly which half."**
   Every product carries its own status and its own reason. Retry pushes only what failed.

4. **"The app will never show me a technical error."**
   Every failure is translated into a sentence with a next step before it reaches the screen.

---

# Part 5 — What the user cannot do yet, and why

Worth knowing so nobody promises these in a demo. Each is a limit of the public catalog platform
the products are published onto, not of the app.

| The user expects | What actually happens |
|---|---|
| Out-of-stock shows on the public page | It does not. The flag filters their own list only. The app says so at the point of setting it. |
| Tags are visible to customers | They are not. Tags are a private organising tool. |
| Website and social links appear on the public page | They do not. The app marks these fields as app-only. |
| My drag order is the customer's order | Ordering inside the app is reliable. Pushing that exact order to the public page is only partially supported. |
| iPhone AR works on every product | 3D products carry an iOS AR file, but the public page cannot serve it yet, so iPhone customers get the 3D viewer rather than room placement. |
| Converting a photo-only product to 3D keeps its history | It works, but the product is rebuilt on the public side, so its analytics history restarts. |

---

# Part 6 — What comes next

The next body of work is **same-day restaurant activation**
([`same-day-activation/`](same-day-activation/)). It is planned and not yet built.

It changes who does all of the above. Today the business owner does every step themselves.
Same-day activation adds a **sales rep** who walks into a restaurant with a box of pre-printed QR
standees, does steps 2 through 8 on behalf of the owner in a single visit, puts a standee on the
table, and leaves with the catalog live.

Two things make it possible, and both are new:

- **Pre-printed QR codes.** Standees are printed *before* anyone knows which restaurant gets
  them. Scanning an unassigned one shows a "not live yet" page. Activating one binds it to a
  catalog on the spot. That is why the QR has to resolve through a redirect rather than pointing
  straight at the public page.
- **Publishing before the models exist.** A dish is published as a photo the same afternoon and
  quietly becomes a 3D product hours later when generation finishes, on the same public entry, so
  it keeps the analytics history it accumulated as a photo.

From the restaurant owner's point of view, the entire journey in Part 2 collapses into
"someone came, took photos of my food, and left me a QR code that works."

---

*Grounded against the working tree on 2026-09-03. Client batches F1 through F12 are complete;
same-day activation is planned and unstarted.*
