# ReCapture — Feature Sheet

**As of:** 2026-10-02 · **Code checked:** ReCapture branch `feature/more-customize-for-mirage` · **Features listed:** 163

Every feature of ReCapture, grouped page by page, with who can use it, how to use it and what you should see. Use it to learn the app, to test it, and to send feedback.

> **Testing?** Use [FEATURE-SHEET.csv](FEATURE-SHEET.csv) (open it in Excel or import it into Google Sheets). It has the same rows plus empty **Status / Tester / Date / Feedback / Severity** columns for you to fill in. Quote the feature **ID** (for example `PUB-03`) in any bug report.

> **Editing this sheet:** don't edit this file or the CSV by hand. Change `build_feature_sheet.py` and run `python build_feature_sheet.py`. Both files are rebuilt.

## How to read the sheet

### User types (the access columns)

| Code | User type | Who that is |
|---|---|---|
| **U** | User | Logged-in user with no paid plan (new account, or plan ended) |
| **T** | Taste | Logged-in owner on the Taste plan (1st plan) |
| **S** | Signature | Logged-in owner on the Signature plan (2nd plan, 'Pro') |
| **M** | MasterChef | Logged-in owner on the MasterChef plan (3rd plan, 'Premium') |
| **Ad** | Admin | ADMIN role |
| **Ar** | Artist | MODEL_ARTIST role (3D model artist / staff) |
| **R** | Sales rep | SALES_REP role |
| **H** | Staff helper | Someone an owner added on the Staff screen (Manager or Team member). This column is what they can do on THAT restaurant. On their own account they are a normal User |
| **C** | Customer | Diner who scans the QR. No login, no app - uses the public menu page |

| Symbol | Meaning |
|---|---|
| ✅ | Can use it fully |
| 🔒 | Partly. A plan limit, a lower cap, or the setting is saved but **held back** from the public menu. The row's notes say which |
| ❌ | Cannot use it / does not see it |

**Things to know before testing:**

1. **Roles include the ones below them.** Admin ⊇ Artist ⊇ Sales rep ⊇ User. An Admin can do everything an Artist, a Rep and a User can.
2. **Admin, Artist and Rep are also normal users.** They can have their own catalog. On their own catalog the **plan limits apply exactly as for any owner**. Their ✅ in plan-limited rows means the role allows it, not that the plan is skipped.
3. **Free trial, rep-published (pending payment) and complimentary restaurants get every customization** (MasterChef level), but only 10 3D dishes.
4. **Plan limits act at Publish, not at Save.** An owner can always design and save. Publishing sends only what the plan covers, and the publish screen lists the rest under *Held back on your plan*.
5. **Nothing reaches customers until Publish.** After any edit, check the public menu only after publishing.
6. **Switches.** Some features are hidden until a server switch is on (see [Switches](#switches-that-hide-or-show-features)). If a feature is missing, check its switch before reporting a bug.

## Contents

1. [Sign-in & app start](#1-sign-in--app-start) · `AUTH` · 6 features
2. [Home page (Projects)](#2-home-page-projects) · `HOME` · 6 features
3. [Inside a project: 3D capture flow](#3-inside-a-project-3d-capture-flow) · `CAP` · 9 features
4. [Inside a project: upload, 3D model, AR](#4-inside-a-project-upload-3d-model-ar) · `MODEL` · 9 features
5. [Catalog page (main screen)](#5-catalog-page-main-screen) · `CAT` · 10 features
6. [Inside catalog: products (dishes)](#6-inside-catalog-products-dishes) · `PROD` · 14 features
7. [Inside catalog: categories (menu sections)](#7-inside-catalog-categories-menu-sections) · `SEC` · 5 features
8. [Inside catalog: look, branding & restaurant info](#8-inside-catalog-look-branding--restaurant-info) · `LOOK` · 13 features
9. [Inside catalog: customer engagement & business value](#9-inside-catalog-customer-engagement--business-value) · `GROW` · 8 features
10. [Inside catalog: AI tools](#10-inside-catalog-ai-tools) · `AI` · 2 features
11. [Inside catalog: daily edits, staff & branches](#11-inside-catalog-daily-edits-staff--branches) · `TEAM` · 6 features
12. [Inside catalog: preview, publish, QR & standees](#12-inside-catalog-preview-publish-qr--standees) · `PUB` · 12 features
13. [Subscription & payments (owner)](#13-subscription--payments-owner) · `SUB` · 7 features
14. [User profile page](#14-user-profile-page) · `PROF` · 7 features
15. [Notifications](#15-notifications) · `NOTI` · 4 features
16. [Sales rep area](#16-sales-rep-area) · `REP` · 12 features
17. [Model Artist / staff tools](#17-model-artist--staff-tools) · `ART` · 9 features
18. [Admin area](#18-admin-area) · `ADM` · 8 features
19. [Public menu - what customers see (Mirage)](#19-public-menu---what-customers-see-mirage) · `MENU` · 16 features
20. [Plans at a glance](#plans-at-a-glance)
21. [Switches that hide or show features](#switches-that-hide-or-show-features)
22. [Known limits: don't report these as bugs](#known-limits-dont-report-these-as-bugs)
23. [How to give feedback](#how-to-give-feedback)

---

## 1. Sign-in & app start

**Where:** Splash → Login → OTP  
How anyone gets into the app. There are no passwords: sign-in is a one-time code (OTP).

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `AUTH-01` | **Splash screen** | App launch | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 2 | `AUTH-02` | **Log in with phone number** | Login screen → Phone tab | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 3 | `AUTH-03` | **Log in with email** | Login screen → Email tab | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 4 | `AUTH-04` | **Enter / resend OTP** | OTP screen | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 5 | `AUTH-05` | **Stay signed in** | Whole app | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 6 | `AUTH-06` | **Protected pages** | Any deep link | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 1. `AUTH-01` Splash screen

- **What it is:** First screen while the app loads ('Preparing capture tools…'). Decides whether to show Login or go straight to Home.
- **How to use / test:**
  1. Kill the app.
  2. Open it again.
- **Expected result:** Signed in → lands on Projects (Home). Signed out → lands on Login.
- **Platform:** APK · Web

#### 2. `AUTH-02` Log in with phone number

- **What it is:** Sign in with a mobile number. A one-time code is sent and typed on the next screen.
- **How to use / test:**
  1. Open the app signed out.
  2. Choose Phone, enter a 10-digit number.
  3. Tap Send OTP.
- **Expected result:** OTP screen opens showing 'Sent to <number>'. Too many tries shows 'Too many attempts — try again in Ns'.
- **Notes:** Depends on the SMS provider being on. If SMS is not running, test with Email.
- **Platform:** APK · Web

#### 3. `AUTH-03` Log in with email

- **What it is:** Same as phone sign-in, but the code is sent by email.
- **How to use / test:**
  1. Choose Email.
  2. Enter an email address.
  3. Tap Send OTP.
- **Expected result:** Code arrives by email; OTP screen opens.
- **Platform:** APK · Web

#### 4. `AUTH-04` Enter / resend OTP

- **What it is:** Type the code to finish signing in. 'Resend code' unlocks after a countdown. A wrong code says 'Incorrect code, try again'.
- **How to use / test:**
  1. Type a wrong code → Verify.
  2. Type the right code → Verify.
  3. Wait for the timer and tap Resend code.
- **Expected result:** Wrong code is refused with a message; right code opens Home. The code locks after 5 wrong guesses.
- **Notes:** Dev/test builds show the code on screen in a 'FOR DEV ONLY' box. This must NOT be visible in a production build - please report it if you see it there.
- **Platform:** APK · Web

#### 5. `AUTH-05` Stay signed in

- **What it is:** The session is remembered. Closing the app or the browser tab does not sign you out.
- **How to use / test:**
  1. Sign in.
  2. Close the app for a few hours (or a day).
  3. Reopen.
- **Expected result:** Still signed in, no OTP asked.
- **Platform:** APK · Web

#### 6. `AUTH-06` Protected pages

- **What it is:** Pages that need an account cannot be opened signed out; pages for a role (Rep / Admin) cannot be opened without that role.
- **How to use / test:**
  1. Signed out, open a deep link such as /catalog on web.
  2. As a plain User, try /rep/catalogs or /admin/standees.
- **Expected result:** Signed out → sent to Login. Wrong role → sent back to a normal page, never a broken screen.
- **Platform:** Web (deep links), APK

</details>

---

## 2. Home page (Projects)

**Where:** Opens after sign-in  
The Projects list is the app's home. Each project is one object being photographed and turned into a 3D model. The top bar has the notification bell, the Catalog button and the profile picture.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 7 | `HOME-01` | **Projects list** | Home | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 8 | `HOME-02` | **Top bar: bell, Catalog, profile picture** | Home → top right | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 9 | `HOME-03` | **Create a project (+ button)** | Home → red + button | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 10 | `HOME-04` | **Project card actions** | Home → a project card | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 11 | `HOME-05` | **Rename / delete a project** | Project card → ⋮ (Project options) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 12 | `HOME-06` | **My projects / Live projects tabs** | Home → tabs at top | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 7. `HOME-01` Projects list

- **What it is:** Every project you created, newest first, with its status (Uploading…, Processing…, ready) and 'Updated <time ago>'.
- **How to use / test:**
  1. Open Home.
  2. Pull down to refresh.
- **Expected result:** Your projects appear as cards. A fresh account sees an empty state with a button to start the first capture.
- **Notes:** Loading text must not mention API names (it should read like 'Fetching your projects').
- **Platform:** APK · Web

#### 8. `HOME-02` Top bar: bell, Catalog, profile picture

- **What it is:** Bell = notifications (with unread count). Catalog = your storefront. Avatar = your profile (shows your photo if you set one).
- **How to use / test:**
  - Tap each of the three icons.
- **Expected result:** Bell → Notifications; Catalog → Catalog page; Avatar → Profile.
- **Platform:** APK · Web

#### 9. `HOME-03` Create a project (+ button)

- **What it is:** Starts a new project. First asks HOW you want to capture: Full Capture, Maya AI Capture, or (staff only) Upload photos.
- **How to use / test:**
  1. Tap +.
  2. Pick a capture mode → Continue.
  3. Enter project name and object size → Create & Continue.
- **Expected result:** Dismissing the sheet goes nowhere. After Create, the capture checklist opens.
- **Notes:** 'Upload photos' is shown only to Artist and Admin.
- **Platform:** APK · Web

#### 10. `HOME-04` Project card actions

- **What it is:** Buttons change with the project's state: Resume (unfinished capture), Retry (failed upload), Generate 3D model, Models, View.
- **How to use / test:**
  - Use projects in different states and tap the button shown on each.
- **Expected result:** Each button opens the right screen; a project with a ready model shows 'Models' instead of 'Generate 3D model'.
- **Platform:** APK · Web

#### 11. `HOME-05` Rename / delete a project

- **What it is:** Rename the project, or delete it.
- **How to use / test:**
  1. Tap ⋮ on a card.
  2. Rename, save.
  3. Delete another project.
- **Expected result:** Name updates at once; deleted project disappears from the list.
- **Platform:** APK · Web

#### 12. `HOME-06` My projects / Live projects tabs

- **What it is:** Staff see two tabs: their own projects, and 'Live projects' - finished uploads from ALL users, for model work.
- **How to use / test:**
  - Sign in as Artist or Admin and switch tabs.
- **Expected result:** Normal users see no tabs. Live tab has no + button (read-only list).
- **Notes:** Details of the Live tab are in section ART (Model Artist / staff tools).
- **Platform:** APK · Web

</details>

---

## 3. Inside a project: 3D capture flow

**Where:** Home → + → capture screens  
The guided camera flow that photographs an object from all sides so a 3D model can be built.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 13 | `CAP-01` | **Full Capture (48 photos)** | + → Full Capture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 14 | `CAP-02` | **Maya AI Capture (6 photos)** | + → Maya AI Capture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 15 | `CAP-03` | **Pre-capture checklist** | Before the camera opens | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 16 | `CAP-04` | **Camera permission screen** | Before the camera opens | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 17 | `CAP-05` | **Level intros (A, B, C)** | Between rings | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 18 | `CAP-06` | **Live coaching / quality gate** | Camera screen | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 19 | `CAP-07` | **Review grid & retake** | After each ring | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 20 | `CAP-08` | **Cancel / resume a capture** | Camera → back | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 21 | `CAP-09` | **Capture summary** | End of capture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 13. `CAP-01` Full Capture (48 photos)

- **What it is:** Highest quality. 48 photos in rings around the object (16/16/16 when the bottom can be shot, 24/24 when it cannot). The app takes shots automatically as you walk round.
- **How to use / test:**
  1. + → Full Capture → create project.
  2. Follow the levels A → B → C.
- **Expected result:** All rings complete, summary screen shows 48 photos.
- **Platform:** APK (phone camera). Web: please verify

#### 14. `CAP-02` Maya AI Capture (6 photos)

- **What it is:** Fast mode: one ring of 6 photos, about a minute. The 3D model starts building automatically after upload.
- **How to use / test:**
  1. + → Maya AI Capture.
  2. Take 6 photos in one circle.
- **Expected result:** Upload starts, then the model builds on its own without pressing Generate.
- **Platform:** APK. Web: please verify

#### 15. `CAP-03` Pre-capture checklist

- **What it is:** Tick each preparation item (light, clear background…) and answer 'Can you photograph the bottom?' - this picks the ring layout.
- **How to use / test:**
  - Try Start before ticking everything, then tick all.
- **Expected result:** Start stays disabled until every required item is ticked.
- **Platform:** APK · Web

#### 16. `CAP-04` Camera permission screen

- **What it is:** Explains and asks for camera / motion permission. Handles 'denied' and 'denied forever' (opens phone settings).
- **How to use / test:**
  - Deny the permission once, then allow it.
- **Expected result:** Clear explanation, a way to retry, and a link to settings when blocked.
- **Platform:** APK

#### 17. `CAP-05` Level intros (A, B, C)

- **What it is:** Before each ring a short screen explains the angle to hold (eye level, from above, from below).
- **How to use / test:**
  - Go through a Full Capture.
- **Expected result:** Each level shows its intro before the camera.
- **Platform:** APK · Web

#### 18. `CAP-06` Live coaching / quality gate

- **What it is:** The app refuses blurry, too-dark or shaky photos and tells you to tilt up/down when the angle is wrong - as it happens.
- **How to use / test:**
  - Shake the phone, cover the lens, tilt far down while capturing.
- **Expected result:** Bad shots are rejected with a clear on-screen message; good ones are counted.
- **Platform:** APK

#### 19. `CAP-07` Review grid & retake

- **What it is:** Grid of the photos just taken. Tap any one to retake it.
- **How to use / test:**
  - Finish a ring, open a photo, retake it.
- **Expected result:** Only that one photo is replaced.
- **Platform:** APK · Web

#### 20. `CAP-08` Cancel / resume a capture

- **What it is:** Leaving mid-capture asks to confirm. The project keeps its progress and shows 'Resume' on Home.
- **How to use / test:**
  - Leave halfway, go Home, tap Resume.
- **Expected result:** Capture continues from where you stopped.
- **Platform:** APK · Web

#### 21. `CAP-09` Capture summary

- **What it is:** Totals per ring before upload; blocks upload if a ring is incomplete (Full mode offers remedies).
- **How to use / test:**
  - Finish a capture.
- **Expected result:** Summary shows counts; Upload button available when complete.
- **Platform:** APK · Web

</details>

---

## 4. Inside a project: upload, 3D model, AR

**Where:** After capture / Project card  
What happens after the photos are taken: upload, model building, viewing and improving the model.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 22 | `MODEL-01` | **Background upload** | Uploading screen | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 23 | `MODEL-02` | **Upload failed → retry** | Upload failed screen / card Retry | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 24 | `MODEL-03` | **Generate 3D model** | Project card → Generate 3D model | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 25 | `MODEL-04` | **Model history (Models)** | Project card → Models | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 26 | `MODEL-05` | **Create a new version** | Model viewer / Models → Create a new version | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 27 | `MODEL-06` | **View 3D model** | Models → open a model | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 28 | `MODEL-07` | **View in AR (place in room)** | Model viewer → AR | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 29 | `MODEL-08` | **Optimize model** | Models → Optimize | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 30 | `MODEL-09` | **Export model (GLB / USDZ)** | Model viewer → Export model | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 22. `MODEL-01` Background upload

- **What it is:** Photos upload while you use other apps. Losing signal pauses; signal back resumes.
- **How to use / test:**
  - Start an upload, switch to another app, turn mobile data off and on.
- **Expected result:** Upload continues/resumes and completes without starting over.
- **Platform:** APK (background). Web: tab must stay open

#### 23. `MODEL-02` Upload failed → retry

- **What it is:** A failed upload explains why and offers Retry.
- **How to use / test:**
  - Turn on airplane mode during upload, then turn it off and Retry.
- **Expected result:** Upload finishes after Retry.
- **Platform:** APK · Web

#### 24. `MODEL-03` Generate 3D model

- **What it is:** The server picks the best photos and starts building the model. A full screen explains what was decided and shows progress.
- **How to use / test:**
  - On a finished capture, tap Generate 3D model.
- **Expected result:** Build screen shows progress; you can leave and come back. A refusal is explained in plain words.
- **Notes:** Owners have a daily limit on generations.
- **Platform:** APK · Web

#### 25. `MODEL-04` Model history (Models)

- **What it is:** One project can have several models (first try, new versions, optimized copy). All are listed, not just the newest.
- **How to use / test:**
  - Open Models on a project with 2+ models.
- **Expected result:** Every version is listed with its status.
- **Platform:** APK · Web

#### 26. `MODEL-05` Create a new version

- **What it is:** Builds a fresh model from the same capture when the first one came out wrong.
- **How to use / test:**
  - Open a model → Create a new version.
- **Expected result:** A new entry appears in Models and builds.
- **Platform:** APK · Web

#### 27. `MODEL-06` View 3D model

- **What it is:** Spin and zoom the model on screen.
- **How to use / test:**
  - Open any ready model.
- **Expected result:** Model loads and can be rotated.
- **Platform:** APK · Web

#### 28. `MODEL-07` View in AR (place in room)

- **What it is:** Place the model on your real table through the camera.
- **How to use / test:**
  - Open a model on an AR-capable phone → View in AR.
- **Expected result:** Model appears in the room at real size. On desktop browser the AR button is hidden.
- **Platform:** APK · mobile Web (AR-capable phones)

#### 29. `MODEL-08` Optimize model

- **What it is:** Makes a smaller, faster-loading copy for customers' phones. Shows as its own entry ('Optimized for fast loading').
- **How to use / test:**
  - Tap Optimize on a large model.
- **Expected result:** A smaller version appears beside the original.
- **Platform:** APK · Web

#### 30. `MODEL-09` Export model (GLB / USDZ)

- **What it is:** Download the model file: GLB (Blender, Unity, web) or USDZ (iPhone Quick Look).
- **How to use / test:**
  - Export both formats.
- **Expected result:** Files download and open in a 3D viewer.
- **Platform:** APK · Web

</details>

---

## 5. Catalog page (main screen)

**Where:** Home → Catalog button  
The catalog is the restaurant's storefront - the menu customers open when they scan the QR. Everything here is a DRAFT until Publish is pressed. One account = one catalog (plus branches, see TEAM-06).

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 31 | `CAT-01` | **Create catalog** | Catalog → empty state → Create catalog | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 32 | `CAT-02` | **Catalog header & status chips** | Catalog → top card | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 33 | `CAT-03` | **Main buttons: Publish, Preview, Analytics, QR code, Download QR/standee** | Catalog → header buttons | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 34 | `CAT-04` | **Edit menu (⋮ More)** | Catalog → ⋮ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 35 | `CAT-05` | **Payment banners on the catalog** | Catalog → banner under header | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 36 | `CAT-06` | **Product grid** | Catalog → Products | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 37 | `CAT-07` | **Search, filter, sort** | Catalog → Products → search / Show / Sort | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 38 | `CAT-08` | **Select several (bulk actions)** | Catalog → Select | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 39 | `CAT-09` | **Delete catalog** | Catalog → ⋮ → Delete catalog | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 40 | `CAT-10` | **Restaurants I help run (helper entry)** | Catalog → empty state | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 31. `CAT-01` Create catalog

- **What it is:** First-time setup: name the catalog. The public link created at first publish never changes after that.
- **How to use / test:**
  - New account → Catalog → Create catalog → enter name.
- **Expected result:** Catalog screen appears with 0 products, status Draft.
- **Platform:** APK · Web

#### 32. `CAT-02` Catalog header & status chips

- **What it is:** Shows name, business name, status (Draft / Live / Offline), 'Draft changes not yet live', 'Publishing…', plan chip, and product/category counts.
- **How to use / test:**
  - Edit any product after publishing.
- **Expected result:** 'Draft changes not yet live' appears, and clears after the next publish.
- **Platform:** APK · Web

#### 33. `CAT-03` Main buttons: Publish, Preview, Analytics, QR code, Download QR/standee

- **What it is:** The five main actions. 'QR code' shows once the catalog has a public link; 'Download QR/standee' only while it is Live.
- **How to use / test:**
  - Check each button with a never-published, a live and an offline catalog.
- **Expected result:** Buttons appear/disappear by state exactly as described.
- **Platform:** APK · Web

#### 34. `CAT-04` Edit menu (⋮ More)

- **What it is:** Menu with: Languages & translations, Spotlight & customer buttons, Offers & happy hour, My plate, Today: stock & prices, Staff, Outlets & branches, Appearance & Theme, Import menu from photos, AI descriptions, Customers, Order & booking links, Menu web address, Delete catalog.
- **How to use / test:**
  - Open ⋮ and tap each item.
- **Expected result:** Each opens its screen. Items behind a switch are hidden when the switch is off (see Notes).
- **Notes:** Hidden until 'appearanceEnabled' is on: Languages, Spotlight, Menu web address, palette & badge icons. Hidden until the AI key is set: Import menu, AI descriptions. The old 'Printable menu' option has been removed - report it if you still see it.
- **Platform:** APK · Web

#### 35. `CAT-05` Payment banners on the catalog

- **What it is:** Shows plan problems with a button: 'Pay now' (payment due / grace), 'Pay to switch it back on' (page switched off), 'Restore 3D' (3D paused).
- **How to use / test:**
  - Use catalogs in each state (pending payment, grace, paused, switched off).
- **Expected result:** Correct banner and button per state; the button opens Subscription.
- **Platform:** APK · Web

#### 36. `CAT-06` Product grid

- **What it is:** All products as cards: picture, price, 3D or Image only, Out of stock, Archived.
- **How to use / test:**
  - Open a catalog with 10+ products, scroll, Load more.
- **Expected result:** Cards show the right badges and price.
- **Platform:** APK · Web

#### 37. `CAT-07` Search, filter, sort

- **What it is:** Search by name; filter by category, type (3D / image) and status; sort by Menu order, Name A–Z, Newest, Oldest, Price.
- **How to use / test:**
  - Combine a search with a filter, then Clear filters.
- **Expected result:** List narrows correctly; empty result says 'No products match'.
- **Platform:** APK · Web

#### 38. `CAT-08` Select several (bulk actions)

- **What it is:** Pick many products and Archive, Delete or Move to category in one go. Failed ones stay selected with 'Retry failed'.
- **How to use / test:**
  - Select 3 products → Move to category; then Archive them.
- **Expected result:** All 3 move/archive; a toast confirms.
- **Platform:** APK · Web

#### 39. `CAT-09` Delete catalog

- **What it is:** Deletes the catalog AND its public page. The only action that gives up the QR link. You must type the catalog name.
- **How to use / test:**
  - Use a test catalog only. Type a wrong name, then the right one.
- **Expected result:** Wrong name keeps the button disabled; right name deletes and returns to the empty state.
- **Notes:** Destructive - test on a throw-away catalog.
- **Platform:** APK · Web

#### 40. `CAT-10` Restaurants I help run (helper entry)

- **What it is:** If someone added you as staff and you have no catalog of your own, the Catalog page shows 'Restaurants I help run' (and 'Create my own catalog').
- **How to use / test:**
  - Have an owner add your number on Staff, sign in with that number, open Catalog.
- **Expected result:** Opens the list of restaurants you help with (see TEAM-05).
- **Platform:** APK · Web

</details>

---

## 6. Inside catalog: products (dishes)

**Where:** Catalog → Add product / tap a product  
Adding and editing the items on the menu.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 41 | `PROD-01` | **Add product from a finished capture (3D)** | Catalog → Add product → From a finished capture | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 42 | `PROD-02` | **Add product as image only** | Add product → Image only — no AR | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 43 | `PROD-03` | **Product details: name, price, description, category, featured, stock** | Add / Edit product | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 44 | `PROD-04` | **Veg / non-veg / none mark** | Edit product → Veg / non-veg | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 45 | `PROD-05` | **Tags** | Edit product → Tags | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 46 | `PROD-06` | **Diet & allergens, spice, serves, prep time** | Edit product → Diet & allergens | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 47 | `PROD-07` | **Badges on a dish** | Edit product → Badges | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 48 | `PROD-08` | **Goes well with (pairings)** | Edit product → Goes well with | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 49 | `PROD-09` | **Other languages (dish translation)** | Edit product → Other languages | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 50 | `PROD-10` | **Change 3D model** | Edit product → Change 3D model | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 51 | `PROD-11` | **Replace photo / switch to 3D** | Edit product → Replace photo / Use a 3D model instead | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 52 | `PROD-12` | **Duplicate product** | Edit product → Duplicate product | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 53 | `PROD-13` | **Archive / restore / delete permanently** | Edit product or card menu | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 54 | `PROD-14` | **AI: write description / enhance photo** | Edit product → ✨ buttons | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 41. `PROD-01` Add product from a finished capture (3D)

- **What it is:** Pick one of your captures, then pick exactly which model version to use (preview each first).
- **How to use / test:**
  - Add product → From a finished capture → pick capture → pick model → name, price → Add product.
- **Expected result:** Product appears with a 3D badge and an automatic thumbnail.
- **Notes:** 3D dishes count toward the plan cap: Trial 10, Taste 10, Signature 15, MasterChef 30.
- **Platform:** APK · Web

#### 42. `PROD-02` Add product as image only

- **What it is:** A photo, name and price is a full product, with no 3D/AR. JPEG, PNG or WebP up to 5 MB.
- **How to use / test:**
  - Add product → Image only → choose photo → name → Add.
- **Expected result:** Product shows 'Image only'. Unlimited on every plan.
- **Platform:** APK · Web

#### 43. `PROD-03` Product details: name, price, description, category, featured, stock

- **What it is:** Basic fields. Price optional ('No price set'). Featured sorts first. In/Out of stock.
- **How to use / test:**
  - Edit each field and Save changes.
- **Expected result:** Toast confirms; 'This is a draft edit. Customers see it after you publish.'
- **Platform:** APK · Web

#### 44. `PROD-04` Veg / non-veg / none mark

- **What it is:** Choose green veg mark, red non-veg mark, or no mark.
- **How to use / test:**
  - Set each of the three values and publish.
- **Expected result:** The public menu shows the chosen mark (or none).
- **Platform:** APK · Web

#### 45. `PROD-05` Tags

- **What it is:** Private labels for your own organising (max 20). Not shown to customers.
- **How to use / test:**
  - Add a few tags.
- **Expected result:** Saved; public menu does not show them.
- **Platform:** APK · Web

#### 46. `PROD-06` Diet & allergens, spice, serves, prep time

- **What it is:** Suitable for (Vegan, Jain, Gluten-free…), Contains (allergens), spice level, serves, minutes. Conflicts (e.g. Vegan + Dairy) are refused.
- **How to use / test:**
  - Fill the section; try Vegan with Dairy.
- **Expected result:** Conflict shows an error; valid details appear on the public dish and power diet filters.
- **Platform:** APK · Web

#### 47. `PROD-07` Badges on a dish

- **What it is:** Put badges from your badge library (Bestseller, Chef's special…) on a dish. The menu card shows the first two.
- **How to use / test:**
  - Create badges first (LOOK-08), then tick 2–3 on a dish.
- **Expected result:** Dish card on the menu shows two badges.
- **Notes:** How many badges show depends on plan: Taste 3, Signature/MasterChef 12.
- **Platform:** APK · Web

#### 48. `PROD-08` Goes well with (pairings)

- **What it is:** Suggest up to 4 dishes to have with this one.
- **How to use / test:**
  - Pick 2 dishes → Save → publish.
- **Expected result:** Dish page on the menu shows 'Goes well with'.
- **Notes:** Saved on every plan; shown on the menu only on Signature+ (held back on Taste).
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 49. `PROD-09` Other languages (dish translation)

- **What it is:** Type the dish name/description in each extra menu language.
- **How to use / test:**
  - Add a language (LOOK-09) then translate one dish.
- **Expected result:** Switching language on the menu shows the translation.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 50. `PROD-10` Change 3D model

- **What it is:** Point the product at a different model version from the same capture, after previewing it.
- **How to use / test:**
  - Change model → pick another → Save → publish.
- **Expected result:** Public dish shows the new model; the QR is unaffected.
- **Platform:** APK · Web

#### 51. `PROD-11` Replace photo / switch to 3D

- **What it is:** Swap the picture, or convert an image-only product into a 3D one.
- **How to use / test:**
  - Replace a photo; convert an image product to 3D.
- **Expected result:** New picture/3D shows after publish.
- **Notes:** Converting restarts that dish's analytics history on the public side.
- **Platform:** APK · Web

#### 52. `PROD-12` Duplicate product

- **What it is:** Copies a product for variants; the copy is renamed automatically.
- **How to use / test:**
  - Duplicate a product.
- **Expected result:** 'Duplicated as "<name> (2)"' and the copy appears.
- **Platform:** APK · Web

#### 53. `PROD-13` Archive / restore / delete permanently

- **What it is:** Archive hides a product without losing it; Restore brings it back; Delete permanently needs typing the name.
- **How to use / test:**
  - Archive → Restore → Delete another one.
- **Expected result:** Archived product leaves the menu at next publish; delete is permanent.
- **Platform:** APK · Web

#### 54. `PROD-14` AI: write description / enhance photo

- **What it is:** 'Write description' gives AI suggestions to pick from. 'Enhance photo' straightens, crops and brightens (Original vs Enhanced).
- **How to use / test:**
  - Tap Write description → pick one. Tap Enhance photo → Use enhanced.
- **Expected result:** Text filled in; enhanced photo saved, shows after publish.
- **Platform:** APK · Web · **Needs switch:** `AI_API_KEY (hidden when not set)`

</details>

---

## 7. Inside catalog: categories (menu sections)

**Where:** Catalog → Categories  
Grouping dishes into sections such as Starters, Mains, Desserts.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 55 | `SEC-01` | **Create / rename / delete category** | Categories → New category / Category options | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 56 | `SEC-02` | **Drag to reorder categories** | Categories → drag handle | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 57 | `SEC-03` | **Move products between categories** | Categories → a category → Add products / Move to… | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 58 | `SEC-04` | **Uncategorized bucket** | Categories | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 59 | `SEC-05` | **Section timings (Available times)** | Categories → Category options → Available times | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 55. `SEC-01` Create / rename / delete category

- **What it is:** Manage sections. Deleting a non-empty one asks where its products should move ('Move and delete').
- **How to use / test:**
  - Create 3, rename 1, delete 1 that has products.
- **Expected result:** Products move to the chosen section; nothing is lost.
- **Platform:** APK · Web

#### 56. `SEC-02` Drag to reorder categories

- **What it is:** Order sections appear on the public menu.
- **How to use / test:**
  - Drag a section to the top.
- **Expected result:** 'Category order saved.'; menu order matches after publish.
- **Platform:** APK · Web

#### 57. `SEC-03` Move products between categories

- **What it is:** Add products into a section or move selected ones to another.
- **How to use / test:**
  - Move 2 products.
- **Expected result:** They now show under the new section.
- **Platform:** APK · Web

#### 58. `SEC-04` Uncategorized bucket

- **What it is:** Products with no section land here. It is always last and cannot be renamed or deleted.
- **How to use / test:**
  - Delete a section and choose Uncategorized.
- **Expected result:** Products appear under Uncategorized.
- **Platform:** APK · Web

#### 59. `SEC-05` Section timings (Available times)

- **What it is:** Serve a section only at certain hours (e.g. Breakfast 7–11). Outside: hide it, or show it greyed with its hours. India time.
- **How to use / test:**
  - Set Breakfast 07:00–11:00, publish, open menu after 11.
- **Expected result:** Section hidden or greyed outside the window.
- **Notes:** Saved on every plan; shown only on Signature+.
- **Platform:** APK · Web

</details>

---

## 8. Inside catalog: look, branding & restaurant info

**Where:** Catalog → header icons / ⋮ / Business profile  
Make the menu look like the restaurant's own. Rule for all of these: you can always SAVE; the publish only sends what the plan covers, and the publish screen lists the rest as 'Held back on your plan'. Upgrading and republishing restores it - nothing is deleted.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 60 | `LOOK-01` | **Business profile** | Catalog → badge icon (Business profile) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 61 | `LOOK-02` | **Appearance & Theme** | Catalog → palette icon, or ⋮ → Appearance & Theme (always shown) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 62 | `LOOK-03` | **Custom primary & accent colours** | Appearance → Customize colours | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 63 | `LOOK-04` | **Layout & fonts** | Appearance → Layout / Fonts | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 64 | `LOOK-05` | **Diet filters on the menu** | Appearance → Diet filters | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 65 | `LOOK-06` | **Opening hours & holidays** | Business profile → Opening hours & holidays | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 66 | `LOOK-07` | **Announcement strip** | Catalog → Announcement | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 67 | `LOOK-08` | **Badge library** | Catalog → tag icon (Badges) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 68 | `LOOK-09` | **Menu languages** | ⋮ → Languages & translations → Choose languages | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 69 | `LOOK-10` | **Translations editor** | ⋮ → Languages & translations | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 70 | `LOOK-11` | **3D & AR style** | Appearance → 3D & AR style | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 71 | `LOOK-12` | **Branded QR style** | QR code → QR style | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 72 | `LOOK-13` | **Menu web address** | ⋮ → Menu web address | 🔒 | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 60. `LOOK-01` Business profile

- **What it is:** Storefront name, logo, cover image, legal name, phone, WhatsApp, email, address, website, social links. The screen marks which fields reach the public page.
- **How to use / test:**
  - Fill every field, upload logo and cover (16:9), Save profile, publish.
- **Expected result:** Public page shows logo, cover banner and the fields marked 'Shown on your public page'.
- **Notes:** Rep: also for restaurants they activated (Restaurant details).
- **Platform:** APK · Web

#### 61. `LOOK-02` Appearance & Theme

- **What it is:** Pick a theme preset; see a live phone preview; Save look; publish.
- **How to use / test:**
  - Choose a different preset → Save look → Publish → open the public menu.
- **Expected result:** Public menu uses the new theme after publish.
- **Notes:** Rep: also for restaurants they activated.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 62. `LOOK-03` Custom primary & accent colours

- **What it is:** Your own brand colours (hex). Colours with poor contrast are refused.
- **How to use / test:**
  - Enter a primary and accent → Save → Publish.
- **Expected result:** Signature+: menu uses them. Taste/no plan: publish lists 'Custom colours' as held back.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 63. `LOOK-04` Layout & fonts

- **What it is:** Card layout Grid / List / Large and curated font pairs.
- **How to use / test:**
  - Switch to List and a new font → publish.
- **Expected result:** Menu layout and font change (Signature+).
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 64. `LOOK-05` Diet filters on the menu

- **What it is:** Lets customers filter by Veg only, Jain, Vegan, Gluten-free, No nuts (only filters your dishes actually have).
- **How to use / test:**
  - Turn on, publish, use filter on the menu.
- **Expected result:** Filter chips appear and work.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 65. `LOOK-06` Opening hours & holidays

- **What it is:** Weekly time slots ('Same as Monday' to copy), holidays, and 'Show "Open now" on the menu'. India time.
- **How to use / test:**
  - Set hours, add a holiday, publish, check the menu at different times.
- **Expected result:** Menu shows 'Open · closes 11 pm' / 'Closed' correctly.
- **Notes:** Rep: also for restaurants they activated.
- **Platform:** APK · Web

#### 66. `LOOK-07` Announcement strip

- **What it is:** One-line strip on the menu (info, offer or alert) with optional link and start/end dates.
- **How to use / test:**
  - Save 'Diwali special — 20% off' with an end date, publish.
- **Expected result:** Strip shows while live; disappears after the end date by itself.
- **Platform:** APK · Web

#### 67. `LOOK-08` Badge library

- **What it is:** Design up to 12 badges once (label, colour) and use them on any dish. Starter set provided.
- **How to use / test:**
  - Create 4 badges → Save badges → put them on dishes.
- **Expected result:** Taste shows the first 3 on the menu; Signature/MasterChef show all 12.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 68. `LOOK-09` Menu languages

- **What it is:** Main language plus extra languages from 9 Indian languages. Customers get a language switcher.
- **How to use / test:**
  - Add Hindi → translate → publish → switch language on the menu.
- **Expected result:** Taste: 0 extra languages; Signature: 1; MasterChef: 3. Untranslated text falls back to the main language.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 69. `LOOK-10` Translations editor

- **What it is:** Type translations for every dish, section, badge and the announcement, with progress and 'Only show what still needs translating'.
- **How to use / test:**
  - Translate 2 dishes and a section.
- **Expected result:** Progress updates; menu shows the translations after publish.
- **Notes:** No machine translation - the owner types everything.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 70. `LOOK-11` 3D & AR style

- **What it is:** Branding on the 3D viewer: logo while loading, logo watermark, surface under the dish, dish name & price.
- **How to use / test:**
  - Turn on watermark → Save → publish → open a 3D dish.
- **Expected result:** Viewer shows the logo/watermark (Signature+).
- **Notes:** Needs a logo on the Business profile.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 71. `LOOK-12` Branded QR style

- **What it is:** QR colours (Classic, Charcoal, Navy, Forest, Wine, Espresso), your logo in the centre, frame text, and the standee template.
- **How to use / test:**
  - Pick Navy + logo → Save QR style → download a standee.
- **Expected result:** Signature+: styled QR. Taste: prints plain black & white. A styled code that would not scan is replaced by the plain one automatically.
- **Notes:** Always test a printed code with 2–3 phones.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 72. `LOOK-13` Menu web address

- **What it is:** An easy address like yourname.<menu domain> for Instagram/WhatsApp. The printed QR link never changes.
- **How to use / test:**
  - Enter 'bluecafe' → Save address → publish → open the address.
- **Expected result:** MasterChef: the address opens the menu. Others: held back.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled + MENU_SUBDOMAIN_BASE (DNS)`

</details>

---

## 9. Inside catalog: customer engagement & business value

**Where:** Catalog → ⋮ / Analytics  
Features that help the restaurant sell more and know its customers.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 73 | `GROW-01` | **Chef's spotlight carousel** | ⋮ → Spotlight & customer buttons → Spotlight | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 74 | `GROW-02` | **Customer buttons** | ⋮ → Spotlight & customer buttons → Customer buttons | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 75 | `GROW-03` | **Offers, combos & happy hour** | ⋮ → Offers & happy hour | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 76 | `GROW-04` | **My plate (customer's order list)** | ⋮ → My plate | 🔒 | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 77 | `GROW-05` | **Order & booking links** | ⋮ → Order & booking links | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 78 | `GROW-06` | **Customer list (WhatsApp offers sign-ups)** | ⋮ → Customers | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 79 | `GROW-07` | **Analytics** | Catalog → Analytics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 80 | `GROW-08` | **Weekly report** | Analytics → Weekly reports (or Monday notification) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 73. `GROW-01` Chef's spotlight carousel

- **What it is:** Up to 6 dishes in a carousel at the top of the menu, with an optional title.
- **How to use / test:**
  - Pick 3 dishes → Save spotlight → publish.
- **Expected result:** Carousel at top of the menu (Signature+).
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 74. `GROW-02` Customer buttons

- **What it is:** Rate us (Google review link or Place ID), Order on WhatsApp, Call waiter, Wi-Fi (name + password), Feedback form (1–5 + comment).
- **How to use / test:**
  - Fill all, Save buttons, publish, try each on the menu.
- **Expected result:** Taste / no plan: only 'Rate us' shows. Signature+: all buttons. Feedback replies appear in Analytics.
- **Notes:** Review link must be a Google link. WhatsApp buttons need a WhatsApp number on the Business profile.
- **Platform:** APK · Web · **Needs switch:** `appearanceEnabled`

#### 75. `GROW-03` Offers, combos & happy hour

- **What it is:** Percent off, rupees off, new price, or combo price - on chosen dishes, sections or the whole menu - with days and time windows. Live preview of prices. Up to 20 active.
- **How to use / test:**
  - Create 'Happy hour 5–7 pm, 20% off drinks' → Save → publish → open menu inside and outside the window.
- **Expected result:** Inside the window: struck-through prices, offer strip, Offers pill. Outside: normal prices.
- **Notes:** Swipe an offer left to delete it.
- **Platform:** APK · Web

#### 76. `GROW-04` My plate (customer's order list)

- **What it is:** Lets customers tap + on dishes to build a plate, see a total, and 'Show to waiter' or send on WhatsApp. Option to hide the running total.
- **How to use / test:**
  - Turn on, publish, build a plate on the menu.
- **Expected result:** Plate works on the menu (Signature+). Stats appear in Analytics and the weekly report.
- **Notes:** ON by default - shows at the restaurant's next publish.
- **Platform:** APK · Web

#### 77. `GROW-05` Order & booking links

- **What it is:** Zomato / Swiggy 'Order online' chips, a booking page link, and phone/WhatsApp number for 'Book a table'.
- **How to use / test:**
  - Fill Zomato link and booking link → Save links → publish.
- **Expected result:** Menu shows the chips/button; wrong links (not https://, wrong site) are refused.
- **Platform:** APK · Web

#### 78. `GROW-06` Customer list (WhatsApp offers sign-ups)

- **What it is:** Customers who joined from the menu (with consent). Search, birthdays this week, open WhatsApp chat with a message, mark opted out, delete, Export CSV.
- **How to use / test:**
  - Sign up from the public menu, then open Customers.
- **Expected result:** The person appears; CSV contains only subscribed customers.
- **Notes:** Owner only - reps and helpers cannot see customers. Follows DPDP consent rules.
- **Platform:** APK · Web

#### 79. `GROW-07` Analytics

- **What it is:** Catalog opens, sessions, product views, AR launches, contact clicks, browse taps, QR scans vs direct links; chart or table by day; date range; top products.
- **How to use / test:**
  - Scan the QR a few times and open dishes, then check Analytics.
- **Expected result:** Numbers rise; comparison with the previous period shown.
- **Notes:** Plan card lists 'Per-dish view analytics' for MasterChef, but today every plan sees the same analytics.
- **Platform:** APK · Web

#### 80. `GROW-08` Weekly report

- **What it is:** Every Monday: menu views, visitors, QR scans, AR views, top dishes, busiest hours, daily chart, plates built, offer views and up to 2 tips. Share as image.
- **How to use / test:**
  - On a test restaurant with reports switched on, open the latest report.
- **Expected result:** Report for last week; 'Share as image' produces a picture.
- **Notes:** Reps see reports of their restaurants read-only.
- **Platform:** APK · Web · **Needs switch:** `WEEKLY_REPORTS_ENABLED`

</details>

---

## 10. Inside catalog: AI tools

**Where:** Catalog → ⋮  
AI helpers. All of them are hidden when the server has no AI key. A hard monthly budget (₹2,000 across all restaurants) and 5 imports/day per restaurant apply.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 81 | `AI-01` | **Import menu from photos / PDF** | ⋮ → Import menu from photos | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 82 | `AI-02` | **Bulk AI descriptions** | ⋮ → AI descriptions | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 81. `AI-01` Import menu from photos / PDF

- **What it is:** Photograph a paper menu or pick a PDF (up to 10 pages, 20 MB each). AI reads sections, dishes and prices into a draft you check, tick and add. 'Undo this import' afterwards.
- **How to use / test:**
  - Take photos of a printed menu → Read my menu → check → Add N dishes → then Undo.
- **Expected result:** Dishes added as photo-less drafts; Undo removes them (keeps ones you already edited).
- **Notes:** Rep: also on restaurants they activated.
- **Platform:** APK · Web · **Needs switch:** `AI_API_KEY`

#### 82. `AI-02` Bulk AI descriptions

- **What it is:** Writes descriptions for every dish missing one, in a tone: Casual, Premium or Fun. You pick which to save.
- **How to use / test:**
  - Choose Premium → Write N descriptions → Save.
- **Expected result:** Descriptions saved; 'The AI budget for this month is used up' when the cap is hit.
- **Platform:** APK · Web · **Needs switch:** `AI_API_KEY`

</details>

---

## 11. Inside catalog: daily edits, staff & branches

**Where:** Catalog → ⋮  
Quick day-to-day changes, letting staff help, and running more than one outlet.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 83 | `TEAM-01` | **Today: stock & prices** | ⋮ → Today: stock & prices | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 84 | `TEAM-02` | **Bulk price change** | Today → Select → Change prices | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 🔒 | ❌ |
| 85 | `TEAM-03` | **Recent changes log** | Today → Recent changes | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 86 | `TEAM-04` | **Staff (invite helpers)** | ⋮ → Staff | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 87 | `TEAM-05` | **Helper's view: Restaurants I help run** | Catalog → Restaurants I help run (/staff) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| 88 | `TEAM-06` | **Outlets & branches** | ⋮ → Outlets & branches (or outlet chip) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 83. `TEAM-01` Today: stock & prices

- **What it is:** Every dish in one list: stock switch, price, search, 'sold out only'. Long-press for 'Sold out until tomorrow' (back at 5 am). Changes go in one batch; 'Publish now'.
- **How to use / test:**
  - Mark 2 dishes sold out, change 1 price → Publish now.
- **Expected result:** 'Saved and publishing — live in a few seconds.' Menu shows sold out; the 'until tomorrow' dish returns at 5 am.
- **Notes:** Staff helper: Team member = stock + publish; Manager = stock + prices + publish.
- **Platform:** APK · Web

#### 84. `TEAM-02` Bulk price change

- **What it is:** Change many prices by percent or flat amount, with rounding, preview and a 7-day Undo.
- **How to use / test:**
  - Select a section → +10% → Preview → Apply → Undo.
- **Expected result:** Prices change and then revert with Undo.
- **Notes:** Helper: Manager only.
- **Platform:** APK · Web

#### 85. `TEAM-03` Recent changes log

- **What it is:** Who changed what (owner or which staff member). Kept 90 days.
- **How to use / test:**
  - Make changes as owner and as a helper.
- **Expected result:** Both appear with the right name.
- **Platform:** APK · Web

#### 86. `TEAM-04` Staff (invite helpers)

- **What it is:** Add up to 5 people by mobile number as Manager or Team member. Remove anyone; they lose access at once. Helpers never see billing.
- **How to use / test:**
  - Add a number as Team member → sign in with it → check access → remove it.
- **Expected result:** Helper sees the restaurant; after removal access stops immediately.
- **Notes:** Not plan-gated.
- **Platform:** APK · Web

#### 87. `TEAM-05` Helper's view: Restaurants I help run

- **What it is:** A helper's list of restaurants they were added to; opens that restaurant's Today screen with only their permissions.
- **How to use / test:**
  - Sign in as a helper → open the restaurant.
- **Expected result:** Only Today actions allowed; the server refuses anything else.
- **Platform:** APK · Web

#### 88. `TEAM-06` Outlets & branches

- **What it is:** One main outlet + up to 10 branches. Each branch has its own page, QR, stock, prices, staff, offers and plan. Menu and look are set once on the main outlet and copy down; a branch can override price/stock ('Reset' to main).
- **How to use / test:**
  - Add branch → switch to it with the outlet chip → change one price there → change the dish on main.
- **Expected result:** Branch keeps its own price; other main edits arrive automatically. Brand screens are locked on a branch.
- **Notes:** 'Publish all outlets' button is still present (removal requested in learn.txt, not done yet). Each outlet is billed separately.
- **Platform:** APK · Web

</details>

---

## 12. Inside catalog: preview, publish, QR & standees

**Where:** Catalog → Preview / Publish / QR code  
Checking the draft, putting it live, and getting the printed QR.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 89 | `PUB-01` | **Preview** | Catalog → Preview | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 90 | `PUB-02` | **Publish checklist** | Catalog → Publish | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 91 | `PUB-03` | **Choose a plan at Publish (paywall)** | Publish → plan card | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 92 | `PUB-04` | **Publish with live progress** | Publish | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 93 | `PUB-05` | **Retry failed only** | Publish → Retry failed | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 94 | `PUB-06` | **Held back on your plan** | Publish → card | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 95 | `PUB-07` | **3D dish cap at publish** | Publish | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 96 | `PUB-08` | **Take catalog offline / back live** | Publish → Take offline | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 97 | `PUB-09` | **Public link: copy, share, open** | Publish / QR screen | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 98 | `PUB-10` | **QR code (view)** | Catalog → QR code | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 99 | `PUB-11` | **Download QR/standee (counted)** | Catalog → Download QR/standee, or QR → Download in A4 size | 🔒 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 100 | `PUB-12` | **Activity / publish history** | Publish | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 89. `PUB-01` Preview

- **What it is:** Shows the draft exactly the way a customer will see it, before publishing.
- **How to use / test:**
  - Edit a dish, open Preview.
- **Expected result:** Preview shows the edit even though it is not live.
- **Platform:** APK · Web

#### 90. `PUB-02` Publish checklist

- **What it is:** Lists EVERY problem at once in plain words (no products, missing name, dish without photo, duplicate names, still generating…) with one-tap fixes like 'Use "Lassi (2)" and publish'.
- **How to use / test:**
  - Create two dishes with the same name and a dish without a photo → Publish.
- **Expected result:** Both problems listed together; the rename fix works.
- **Platform:** APK · Web

#### 91. `PUB-03` Choose a plan at Publish (paywall)

- **What it is:** If the catalog has no plan, Publish shows a plan card first. After paying you come back and the publish starts without a second tap.
- **How to use / test:**
  - New account → build a catalog → Publish.
- **Expected result:** Plan card appears; after a (test) payment the publish runs.
- **Notes:** A restaurant set up by a rep can publish before payment - see REP-08.
- **Platform:** APK · Web

#### 92. `PUB-04` Publish with live progress

- **What it is:** Runs in the background (you can leave). Each dish shows Synced / Pending / Failed / Never published with a reason.
- **How to use / test:**
  - Publish 10 dishes, leave the screen and come back.
- **Expected result:** Dishes turn green one by one; 'Your catalog is live.'
- **Platform:** APK · Web

#### 93. `PUB-05` Retry failed only

- **What it is:** If some dishes fail, retry pushes only those.
- **How to use / test:**
  - Turn network off mid-publish, then Retry failed.
- **Expected result:** Only failed ones are re-sent and succeed.
- **Platform:** APK · Web

#### 94. `PUB-06` Held back on your plan

- **What it is:** Lists customizations your plan does not cover (sent with the standard look). Your choices stay saved.
- **How to use / test:**
  - On Taste, set custom colours and an offer → Publish.
- **Expected result:** Card lists 'Custom colours needs the Signature plan' etc.; menu shows standard look.
- **Platform:** APK · Web · **Needs switch:** `subscriptionGatesEnabled`

#### 95. `PUB-07` 3D dish cap at publish

- **What it is:** If you have more 3D dishes than the plan allows (Trial 10, Taste 10, Signature 15, MasterChef 30), publish asks you to upgrade or switch some to image.
- **How to use / test:**
  - On Taste add 11 3D dishes → Publish.
- **Expected result:** Publish explains the cap and offers 'See plans'.
- **Platform:** APK · Web

#### 96. `PUB-08` Take catalog offline / back live

- **What it is:** Removes the dishes from the public page, but the QR and link keep working. Publishing again brings it back.
- **How to use / test:**
  - Take offline → scan QR → Publish again.
- **Expected result:** QR shows the 'not live' message, then the menu again.
- **Platform:** APK · Web

#### 97. `PUB-09` Public link: copy, share, open

- **What it is:** Copy the permanent link, share it, or open it.
- **How to use / test:**
  - Tap Copy link, Share, Open.
- **Expected result:** Link copied/shared/opened. Share button is hidden on web.
- **Platform:** APK · Web

#### 98. `PUB-10` QR code (view)

- **What it is:** Shows the catalog's permanent QR. It never changes on rename or republish.
- **How to use / test:**
  - Republish after renaming; scan the old QR.
- **Expected result:** Old QR still opens the menu.
- **Notes:** The screen is view-only (screenshots blocked on Android). Downloads go through the counted standee download.
- **Platform:** APK · Web

#### 99. `PUB-11` Download QR/standee (counted)

- **What it is:** Download A4 standee PDFs (one QR per page). Ask how many (1 to what's left). Each download uses up your plan's standees: Taste 10, Signature 15, MasterChef 30 - one lifetime pool.
- **How to use / test:**
  - Live catalog → Download → choose 2 → check the remaining count.
- **Expected result:** PDF with 2 standees; remaining count drops by 2; at 0 it says 'Upgrade your plan for more'.
- **Notes:** Only while the catalog is Live.
- **Platform:** APK · Web

#### 100. `PUB-12` Activity / publish history

- **What it is:** What was published when, and what failed.
- **How to use / test:**
  - Publish twice.
- **Expected result:** Both runs listed.
- **Platform:** APK · Web

</details>

---

## 13. Subscription & payments (owner)

**Where:** Profile → Subscription, or Catalog → Pay now  
Plans: Taste ₹1,199/month, Signature ₹1,799/month, MasterChef ₹2,499/month; yearly saves 30%. Free trial 30 days. In test mode prices show as ₹3 / ₹5 / ₹7 with a 'TEST PRICING' banner.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 101 | `SUB-01` | **Your plan (status card)** | Subscription screen → top | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 102 | `SUB-02` | **Plans & compare** | Subscription → Plans | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 103 | `SUB-03` | **Subscribe with autopay (Razorpay)** | Subscription → Continue to <plan> | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 104 | `SUB-04` | **Turn off autopay** | Subscription → Turn off autopay | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 105 | `SUB-05` | **Payment history & receipts** | Subscription → Payment history | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 106 | `SUB-06` | **Free trial** | Started by a rep or admin | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 107 | `SUB-07` | **Grace, pause, payment-due lifecycle** | Catalog banners + notifications | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 101. `SUB-01` Your plan (status card)

- **What it is:** Current plan, status (Trial, Active, Grace, Paused, Complimentary…), end / renewal date, days left, 3D dish usage, standees, 'See catalog'.
- **How to use / test:**
  - Open with a catalog on each status.
- **Expected result:** Card matches the real status and dates.
- **Platform:** APK · Web

#### 102. `SUB-02` Plans & compare

- **What it is:** The three plans with caps and perks, monthly/yearly switch, 'Save 30% with yearly billing', Upgrade to next tier.
- **How to use / test:**
  - Toggle Monthly/Yearly.
- **Expected result:** Prices update correctly; yearly = 12 × monthly − 30%.
- **Platform:** APK · Web

#### 103. `SUB-03` Subscribe with autopay (Razorpay)

- **What it is:** Approve autopay once with UPI, card or net banking; the plan then renews every month/year by itself.
- **How to use / test:**
  - In test pricing mode, subscribe to Taste monthly.
- **Expected result:** 'Payment received — your plan is active.' appears quickly; Autopay is on.
- **Notes:** Use testing prices only.
- **Platform:** APK · iOS · Web (in-app payment)

#### 104. `SUB-04` Turn off autopay

- **What it is:** Stops future renewals; the paid period continues to its end.
- **How to use / test:**
  - Turn off → confirm.
- **Expected result:** 'Autopay turned off' + notification; plan stays until end date.
- **Platform:** APK · Web

#### 105. `SUB-05` Payment history & receipts

- **What it is:** All payments with Download receipt; refunds shown.
- **How to use / test:**
  - Open after a payment.
- **Expected result:** Receipt PDF downloads.
- **Platform:** APK · Web

#### 106. `SUB-06` Free trial

- **What it is:** 30 days, up to 10 3D dishes, every customization unlocked. One trial per restaurant, ever.
- **How to use / test:**
  - Rep starts a trial (REP-09), owner opens Subscription.
- **Expected result:** Shows 'Free trial' with end date.
- **Platform:** APK · Web

#### 107. `SUB-07` Grace, pause, payment-due lifecycle

- **What it is:** Plan ends → 7-day grace (all still works) → 3D paused (photo menu stays live). A rep-published unpaid restaurant has 7 days to pay before the WHOLE page switches off.
- **How to use / test:**
  - Admin can shorten dates on a test catalog to walk through each step.
- **Expected result:** Correct banner, notification and public page behaviour at each step.
- **Notes:** A restaurant that has ever paid never loses its photo menu.
- **Platform:** APK · Web

</details>

---

## 14. User profile page

**Where:** Home → profile picture  
Your own account. Extra rows appear depending on your role.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 108 | `PROF-01` | **Profile photo** | Profile → avatar | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 109 | `PROF-02` | **Name, contact, role, member since** | Profile | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 110 | `PROF-03` | **Subscription row** | Profile → Subscription | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 111 | `PROF-04` | **Rep rows: My restaurants, My standees, Published standees** | Profile | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 112 | `PROF-05` | **Admin rows: Standee inventory, Subscriptions** | Profile | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 113 | `PROF-06` | **All catalogs (admin)** | Profile → All catalogs | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 114 | `PROF-07` | **Sign out** | Profile → Sign out | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 108. `PROF-01` Profile photo

- **What it is:** Choose, replace or remove a photo (JPG/PNG).
- **How to use / test:**
  - Upload a photo, then remove it.
- **Expected result:** Photo shows on Profile and Home top bar.
- **Platform:** APK · Web

#### 109. `PROF-02` Name, contact, role, member since

- **What it is:** Edit your display name. See your masked phone/email, your role badge and 'Member since'.
- **How to use / test:**
  - Edit name → Save.
- **Expected result:** Name updated everywhere.
- **Platform:** APK · Web

#### 110. `PROF-03` Subscription row

- **What it is:** 'Your plan, 3D dish usage and prices' - opens the Subscription screen.
- **How to use / test:**
  - Tap it.
- **Expected result:** Subscription screen opens.
- **Platform:** APK · Web

#### 111. `PROF-04` Rep rows: My restaurants, My standees, Published standees

- **What it is:** Shortcuts into the Sales rep area (section REP).
- **How to use / test:**
  - Sign in as rep, open each row.
- **Expected result:** Rows open the rep screens; a plain User never sees them.
- **Platform:** APK · Web

#### 112. `PROF-05` Admin rows: Standee inventory, Subscriptions

- **What it is:** 'Mint QR codes and send one to a rep' and 'Verify cash payments, comps and who is expiring'.
- **How to use / test:**
  - Sign in as Admin.
- **Expected result:** Rows visible only to Admin.
- **Platform:** APK · Web

#### 113. `PROF-06` All catalogs (admin)

- **What it is:** Grid (2 per row) of every live catalog with name and icon, search, Load more. Open one to see it like a customer; tap the banner to edit and publish it directly (Publish by admin / Unpublish by admin with a reason).
- **How to use / test:**
  - Admin → All catalogs → open one → edit a dish → Publish by admin.
- **Expected result:** Change is live on that restaurant's menu.
- **Notes:** Built and committed on branch feature/subcription-stated-f-noti; NOT yet in feature/more-customize-for-mirage. Test on a build from that branch.
- **Platform:** APK · Web

#### 114. `PROF-07` Sign out

- **What it is:** Ends the session on this device.
- **How to use / test:**
  - Sign out.
- **Expected result:** Back at Login; Back button does not return into the app.
- **Platform:** APK · Web

</details>

---

## 15. Notifications

**Where:** Home → bell  
In-app feed of updates about payments, activation and the catalog (some also go by SMS).

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 115 | `NOTI-01` | **Notification feed** | Bell → Notifications | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 116 | `NOTI-02` | **Subscription notifications** | Feed (+ SMS for some) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 117 | `NOTI-03` | **Weekly report & menu notifications** | Feed | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 118 | `NOTI-04` | **Admin alerts** | Feed | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 115. `NOTI-01` Notification feed

- **What it is:** List with unread state, Details, and 'Mark all read'.
- **How to use / test:**
  - Open feed, open one, Mark all read.
- **Expected result:** Unread count on the bell goes to 0.
- **Platform:** APK · Web

#### 116. `NOTI-02` Subscription notifications

- **What it is:** Trial started, payment received, plan ends in N days, autopay renews in N days, menu live — payment due, live menu switches off in N days, 3D paused, page switched off, deadline extended, 'You have not chosen a plan yet', cash payment awaiting verification, payment not confirmed, autopay on/failed/stopped/turned off, duplicate refunded, comped.
- **How to use / test:**
  - Walk a test catalog through trial → payment → expiry.
- **Expected result:** The matching notification appears at each step, once.
- **Platform:** APK · Web

#### 117. `NOTI-03` Weekly report & menu notifications

- **What it is:** Monday 'See report' notification; 'more 3D dishes than your plan covers'; dish turned 3D after a rep's capture.
- **How to use / test:**
  - With weekly reports on, wait for Monday or trigger the job.
- **Expected result:** Tapping opens the right screen.
- **Platform:** APK · Web

#### 118. `NOTI-04` Admin alerts

- **What it is:** Payment problems for admins: chargebacks, duplicate payments, amount mismatch, payments for unknown/deleted catalogs, 'Razorpay webhooks may be disabled'.
- **How to use / test:**
  - Seen only when such a case happens.
- **Expected result:** Admin receives it; owners never do.
- **Platform:** APK · Web

</details>

---

## 16. Sales rep area

**Where:** Profile → My restaurants (/rep)  
A rep walks into a restaurant with pre-printed QR standees, sets up its menu in one visit and leaves it live. Admin and Artist accounts can use everything here too (roles include everything below them).

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 119 | `REP-01` | **My restaurants** | Profile → My restaurants | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 120 | `REP-02` | **Activate a standee** | My restaurants → Activate a standee | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 121 | `REP-03` | **Scan the standee (camera)** | Activate → Scan the code | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 122 | `REP-04` | **My standees** | Profile → My standees | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 123 | `REP-05` | **Restaurant menu (dishes)** | My restaurants → a restaurant | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 124 | `REP-06` | **Add a dish (capture now / finished capture / image)** | Restaurant → Add a dish | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 125 | `REP-07` | **Edit a dish with live preview** | Restaurant → tap a dish | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 126 | `REP-08` | **Rep publish (before payment)** | Restaurant → Publish the menu | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 127 | `REP-09` | **Subscription card: trial, cash, notify owner** | Restaurant → Subscription card | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 128 | `REP-10` | **Restaurant QR** | My restaurants → Show the QR code | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 129 | `REP-11` | **Published standees (history)** | Profile → Published standees | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 130 | `REP-12` | **Rep access ends** | Any rep restaurant screen | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 119. `REP-01` My restaurants

- **What it is:** Restaurants this rep may act on, each marked 'Menu live' or 'Not published yet', with 'Show the QR code'.
- **How to use / test:**
  - Open as a rep with 2 activated restaurants.
- **Expected result:** Both listed with the right status.
- **Platform:** APK · Web

#### 120. `REP-02` Activate a standee

- **What it is:** Scan the standee QR or type its 8-character code → check → restaurant name + owner's phone (the owner signs in and pays with it) → confirm → 'This standee is live'. Can also activate as a new branch of an existing restaurant.
- **How to use / test:**
  - Activate an unused test code with a test phone number.
- **Expected result:** Restaurant created and linked to the code; owner can sign in with that phone. Used/foreign codes give clear errors.
- **Notes:** Standee assignment to reps is advisory - any rep can activate any free code (by design).
- **Platform:** APK · Web

#### 121. `REP-03` Scan the standee (camera)

- **What it is:** Reads the code from the standee's QR.
- **How to use / test:**
  - Scan a printed standee.
- **Expected result:** Code fills in. No camera → 'Type the code instead'.
- **Platform:** APK · Web

#### 122. `REP-04` My standees

- **What it is:** Standees an admin assigned to you, ready to activate, each with 'Save a printable standee'.
- **How to use / test:**
  - Admin assigns 2 codes → rep opens My standees.
- **Expected result:** Both listed; PDF saves.
- **Platform:** APK · Web

#### 123. `REP-05` Restaurant menu (dishes)

- **What it is:** Dishes list with drag reorder, status (Draft / Everything is live), Add a dish, Categories, Restaurant details, Import menu, Weekly reports, Preview, Publish.
- **How to use / test:**
  - Open a restaurant and use each entry.
- **Expected result:** All entries open; order saves.
- **Platform:** APK · Web

#### 124. `REP-06` Add a dish (capture now / finished capture / image)

- **What it is:** Three ways: 'Capture now' (6 photos; the 3D builds on its own and the dish becomes 3D later), from a finished capture, or image only.
- **How to use / test:**
  - Add one dish each way.
- **Expected result:** Image dish appears at once; 'Capture now' dish shows photo first and turns 3D when the model is ready (same public entry).
- **Platform:** APK · Web (web uses a simple 6-photo camera)

#### 125. `REP-07` Edit a dish with live preview

- **What it is:** Name, price, description, section, veg/non-veg, available today, replace photo - with 'What a customer will see' preview.
- **How to use / test:**
  - Edit a dish → Save dish.
- **Expected result:** 'Dish saved. Publish the menu…'.
- **Platform:** APK · Web

#### 126. `REP-08` Rep publish (before payment)

- **What it is:** Same checklist and progress as the owner. An unpaid restaurant goes live with a 7-day pay-by window; the public page shows a payment-due banner, and switches OFF if not paid in time.
- **How to use / test:**
  - Publish a new unpaid restaurant, scan its standee.
- **Expected result:** Menu is live with the banner; owner gets 'Your menu is live — payment due'.
- **Platform:** APK · Web

#### 127. `REP-09` Subscription card: trial, cash, notify owner

- **What it is:** Start free trial (once per restaurant), Record cash payment (amount, method, reference → admin verifies), Notify owner to pay (SMS + in-app, with a cool-down).
- **How to use / test:**
  - Try each action on a test restaurant.
- **Expected result:** Trial starts; cash shows 'awaiting admin verification'; notify shows 'Sent… again in …'.
- **Platform:** APK · Web

#### 128. `REP-10` Restaurant QR

- **What it is:** The same QR the owner sees, viewable and saveable.
- **How to use / test:**
  - Open QR on a live restaurant.
- **Expected result:** Same code as the owner's.
- **Platform:** APK · Web

#### 129. `REP-11` Published standees (history)

- **What it is:** Restaurants this rep put live, by period. Admin sees every staff member's ('Put live by …').
- **How to use / test:**
  - Pick a period.
- **Expected result:** List with counts; admin sees all reps.
- **Platform:** APK · Web

#### 130. `REP-12` Rep access ends

- **What it is:** If access is removed, screens say 'This restaurant is no longer assigned to you'.
- **How to use / test:**
  - Remove a rep's access, then open the restaurant.
- **Expected result:** Clear message, no crash.
- **Platform:** APK · Web

</details>

---

## 17. Model Artist / staff tools

**Where:** Home → Live projects tab  
For the in-house 3D team (Artist and Admin): see every user's finished uploads and produce or fix their models.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 131 | `ART-01` | **Live projects list** | Home → Live projects | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 132 | `ART-02` | **Project owner details** | Live project → Created by | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 133 | `ART-03` | **Upload photos project** | + → Upload photos | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 134 | `ART-04` | **Preview gallery** | Live project → Preview | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 135 | `ART-05` | **Select photos → Create Model** | Preview → Select photos → Create Model | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 136 | `ART-06` | **Export project files** | Live project → Export | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 137 | `ART-07` | **Staff model history & approve** | Live project → Models | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 138 | `ART-08` | **Submit model (.glb)** | Live project → Submit model | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 139 | `ART-09` | **Delete a user's project** | Live project → Delete project | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 131. `ART-01` Live projects list

- **What it is:** Finished uploads from ALL users, with owner, 'Updated …', and actions.
- **How to use / test:**
  - Open the tab.
- **Expected result:** Projects from other users appear.
- **Platform:** APK · Web

#### 132. `ART-02` Project owner details

- **What it is:** Owner's name, phone, email, role and member since, with copy buttons.
- **How to use / test:**
  - Tap the owner line.
- **Expected result:** Details sheet opens.
- **Platform:** APK · Web

#### 133. `ART-03` Upload photos project

- **What it is:** Create a project from 3–48 gallery photos instead of capturing.
- **How to use / test:**
  - Pick 10 photos → Upload.
- **Expected result:** Project created and uploads.
- **Platform:** APK · Web

#### 134. `ART-04` Preview gallery

- **What it is:** Browse every photo of a project, download single photos; delete a photo (Admin only).
- **How to use / test:**
  - Open Preview, swipe, download one.
- **Expected result:** Photos load; delete is not offered to Artist.
- **Platform:** APK · Web

#### 135. `ART-05` Select photos → Create Model

- **What it is:** Hand-pick 3–4 photos and start a model build.
- **How to use / test:**
  - Select 4 → Create Model.
- **Expected result:** Build starts and shows the selection trace.
- **Platform:** APK · Web

#### 136. `ART-06` Export project files

- **What it is:** Download links for all of a project's files (time-limited).
- **How to use / test:**
  - Tap Export.
- **Expected result:** 'Export ready — N files'; links expire.
- **Platform:** APK · Web

#### 137. `ART-07` Staff model history & approve

- **What it is:** Every generation with its trace; 'Approve this model'; Optimize; Export.
- **How to use / test:**
  - Approve a model.
- **Expected result:** 'Approved — no manual model needed'.
- **Platform:** APK · Web

#### 138. `ART-08` Submit model (.glb)

- **What it is:** Upload a hand-made .glb to a project you do not own; the owner sees it in their Models.
- **How to use / test:**
  - Choose a .glb → submit.
- **Expected result:** 'Model submitted'; owner sees it.
- **Platform:** APK · Web

#### 139. `ART-09` Delete a user's project

- **What it is:** Soft delete (team can restore) or permanent delete, typing the name.
- **How to use / test:**
  - Delete a test project.
- **Expected result:** Project removed from the list.
- **Platform:** APK · Web

</details>

---

## 18. Admin area

**Where:** Profile → Standee inventory / Subscriptions  
Running the business: standee stock, plans and payments. Admin only.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 140 | `ADM-01` | **Standee inventory: mint a batch** | Profile → Standee inventory → Mint a batch | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 141 | `ADM-02` | **Batch: assign, return, download** | Standee inventory → a batch | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 142 | `ADM-03` | **Standee → restaurant** | Batch → Show the restaurant this standee activated | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 143 | `ADM-04` | **Subscriptions: Plans tab** | Subscriptions → Plans | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 144 | `ADM-05` | **Subscriptions: Cash tab** | Subscriptions → Cash | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 145 | `ADM-06` | **Payments journal** | Subscriptions → Payments | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 146 | `ADM-07` | **Payment attempt detail & fixes** | Payments → an attempt | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 147 | `ADM-08` | **Restaurant subscription panel** | Subscriptions → a restaurant | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 140. `ADM-01` Standee inventory: mint a batch

- **What it is:** Create a run of permanent QR codes with a label, count and optional rep to assign them to.
- **How to use / test:**
  - Mint 5 codes labelled 'Test run'.
- **Expected result:** Batch listed with 5 codes.
- **Notes:** Codes are permanent - print and scan a couple first.
- **Platform:** APK · Web

#### 141. `ADM-02` Batch: assign, return, download

- **What it is:** Assign the whole batch or one standee to a rep, reassign, return all to stock, download printable standee sheets (copies per page), download print-vendor CSV.
- **How to use / test:**
  - Assign one code to a rep; download sheets.
- **Expected result:** Rep sees it in My standees; PDF/CSV download.
- **Platform:** APK · Web

#### 142. `ADM-03` Standee → restaurant

- **What it is:** For a used code: the restaurant's QR and who activated it.
- **How to use / test:**
  - Open a used code.
- **Expected result:** Shows the restaurant and the rep.
- **Platform:** APK · Web

#### 143. `ADM-04` Subscriptions: Plans tab

- **What it is:** All restaurants with filters (Pending, All, Expiring 7d, In grace, Paused, Paused 90d+, Trial) and search by restaurant, owner, phone (last 4+) or email.
- **How to use / test:**
  - Use each filter and a search.
- **Expected result:** Lists and empty states are correct; chips fit on mobile.
- **Platform:** APK · Web

#### 144. `ADM-05` Subscriptions: Cash tab

- **What it is:** Cash payments recorded by reps waiting for verification; approve or reject (reason needed).
- **How to use / test:**
  - Rep records cash → admin approves.
- **Expected result:** Plan activates; rep and owner notified.
- **Platform:** APK · Web

#### 145. `ADM-06` Payments journal

- **What it is:** Every online payment attempt: Needs attention, All, Succeeded, Not completed. Find by order_… or pay_… id.
- **How to use / test:**
  - Make a test payment, find it by id.
- **Expected result:** Attempt found with its steps.
- **Platform:** APK · Web

#### 146. `ADM-07` Payment attempt detail & fixes

- **What it is:** Step-by-step journal (started → Razorpay → recorded → applied → catalog), 'Check with Razorpay', 'Apply to catalog' when money arrived but the plan did not, Capture, Refund duplicate.
- **How to use / test:**
  - Open a stuck attempt → Check with Razorpay → Apply.
- **Expected result:** 'Applied — the plan is active on the catalog.'
- **Platform:** APK · Web

#### 147. `ADM-08` Restaurant subscription panel

- **What it is:** Start plan (manual payment), start trial, Comp until a date, Extend grace, standee allowance, Resync page / Resync 3D, ledger and online payments, refunds.
- **How to use / test:**
  - On a test restaurant: Start plan, then Extend grace.
- **Expected result:** Status updates and the owner is notified.
- **Notes:** Production to-do: remove the 'Comp until' option and make 'All' the default filter (learn.txt).
- **Platform:** APK · Web

</details>

---

## 19. Public menu - what customers see (Mirage)

**Where:** Scan the QR / open the public link  
No app and no login. Everything here only changes after the owner (or rep) publishes.

| Sr. | ID | Feature | Where in the app | U | T | S | M | Ad | Ar | R | H | C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 148 | `MENU-01` | **Scan QR → menu** | Phone camera | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 149 | `MENU-02` | **Not-live standee page** | Scan an unused / offline code | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 150 | `MENU-03` | **Theme, cover, layout, fonts** | Menu page | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 151 | `MENU-04` | **Open now, announcement, timed sections** | Menu page top | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 152 | `MENU-05` | **Dish card & details** | Menu → a dish | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 153 | `MENU-06` | **3D view & AR** | Dish → View in AR | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 154 | `MENU-07` | **Search & diet filters** | Menu top | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 155 | `MENU-08` | **Language switcher** | Menu top | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 156 | `MENU-09` | **Spotlight & offers** | Menu top | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 157 | `MENU-10` | **My plate** | Menu → + on dishes | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 158 | `MENU-11` | **Customer buttons** | Menu | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 159 | `MENU-12` | **Google review prompt** | Menu, after some time | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 160 | `MENU-13` | **Join for offers (sign-up)** | Menu → sign-up card | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 161 | `MENU-14` | **Order online / Book a table** | Menu | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 162 | `MENU-15` | **Payment-due banner / page switched off** | Menu | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 163 | `MENU-16` | **Menu web address** | yourname.<menu domain> | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>

#### 148. `MENU-01` Scan QR → menu

- **What it is:** The printed QR opens the restaurant's menu page.
- **How to use / test:**
  - Scan a live restaurant's QR.
- **Expected result:** Menu opens fast on a phone browser.
- **Platform:** Any phone browser

#### 149. `MENU-02` Not-live standee page

- **What it is:** An unassigned standee or offline catalog shows a 'not live yet' page instead of an error.
- **How to use / test:**
  - Scan a fresh minted code.
- **Expected result:** Friendly 'not live' page.
- **Platform:** Any phone browser

#### 150. `MENU-03` Theme, cover, layout, fonts

- **What it is:** The restaurant's own look as published.
- **How to use / test:**
  - Change theme in the app, publish, reload.
- **Expected result:** New look, no flash of the old one.
- **Platform:** Any phone browser

#### 151. `MENU-04` Open now, announcement, timed sections

- **What it is:** 'Open · closes 11 pm' chip and weekly table, announcement strip, sections hidden/greyed outside their hours (India time).
- **How to use / test:**
  - Check at different times of day.
- **Expected result:** Matches the hours set in the app.
- **Platform:** Any phone browser

#### 152. `MENU-05` Dish card & details

- **What it is:** Photo or 3D, price, veg mark, badges, diet & allergens, spice, serves, prep time, pairings.
- **How to use / test:**
  - Open a fully filled dish.
- **Expected result:** All filled fields show; empty ones are hidden.
- **Platform:** Any phone browser

#### 153. `MENU-06` 3D view & AR

- **What it is:** Spin the dish in 3D and place it on the table (AR-capable phones), with restaurant branding.
- **How to use / test:**
  - Android and iPhone.
- **Expected result:** Android: AR placement. iPhone: currently the 3D viewer (room placement not yet served).
- **Platform:** Phone browser

#### 154. `MENU-07` Search & diet filters

- **What it is:** Search dishes; filter Veg only / Jain / Vegan / Gluten-free / No nuts.
- **How to use / test:**
  - Search and filter.
- **Expected result:** Correct dishes shown.
- **Platform:** Any phone browser

#### 155. `MENU-08` Language switcher

- **What it is:** Switch the menu into the extra languages; untranslated text shows in the main language.
- **How to use / test:**
  - Switch to Hindi.
- **Expected result:** Translated names/sections.
- **Platform:** Any phone browser

#### 156. `MENU-09` Spotlight & offers

- **What it is:** Spotlight carousel; offer strip, Offers pill and struck-through prices during offer windows.
- **How to use / test:**
  - Open during a happy hour.
- **Expected result:** Offer prices shown, minute-accurate.
- **Platform:** Any phone browser

#### 157. `MENU-10` My plate

- **What it is:** Build a plate, see the total, 'Show to waiter' (big text) or send on WhatsApp; table number comes from the QR (?t=). Clears after 4 hours.
- **How to use / test:**
  - Add 3 dishes → Show to waiter.
- **Expected result:** Clean list with total.
- **Platform:** Any phone browser

#### 158. `MENU-11` Customer buttons

- **What it is:** Rate us, Order on WhatsApp, Call waiter, Wi-Fi, Feedback form (one per visitor per day).
- **How to use / test:**
  - Try each.
- **Expected result:** Each works; feedback appears in the owner's Analytics.
- **Platform:** Any phone browser

#### 159. `MENU-12` Google review prompt

- **What it is:** 'Enjoyed your meal? Rate us on Google' - asked once a month after 15 minutes; never filters by star rating.
- **How to use / test:**
  - Stay on the menu 15 min.
- **Expected result:** Prompt appears once.
- **Platform:** Any phone browser

#### 160. `MENU-13` Join for offers (sign-up)

- **What it is:** Name + number with an unticked consent box; opt-out later.
- **How to use / test:**
  - Join with a test number.
- **Expected result:** Appears in the owner's Customers list.
- **Platform:** Any phone browser

#### 161. `MENU-14` Order online / Book a table

- **What it is:** Zomato / Swiggy chips and Book a table button.
- **How to use / test:**
  - Tap each.
- **Expected result:** Opens the right page.
- **Platform:** Any phone browser

#### 162. `MENU-15` Payment-due banner / page switched off

- **What it is:** For a rep-published unpaid restaurant: a banner addressed to the owner; after the deadline the whole page is switched off.
- **How to use / test:**
  - Use a test restaurant in pending payment.
- **Expected result:** Banner shows (no prices / 'unpaid' wording); after deadline, page off.
- **Platform:** Any phone browser

#### 163. `MENU-16` Menu web address

- **What it is:** MasterChef restaurants' easy address opens the same menu.
- **How to use / test:**
  - Open the address.
- **Expected result:** Same menu as the QR.
- **Platform:** Any browser

</details>

---

## Plans at a glance

What each plan shows on the **public menu**. Everything can still be designed and saved on any plan.

| | Trial / Pending payment / Comped | Taste (1st) | Signature (2nd) | MasterChef (3rd) |
|---|---|---|---|---|
| Price per month | Free 30 days | ₹1,199 | ₹1,799 | ₹2,499 |
| Yearly billing | - | 30% off | 30% off | 30% off |
| 3D / AR dishes | 10 | 10 | 15 | 30 |
| Image-only dishes | Unlimited | Unlimited | Unlimited | Unlimited |
| Standee downloads (lifetime) | - | 10 | 15 | 30 |
| Theme presets, cover, hours, announcement, diet filters | ✅ | ✅ | ✅ | ✅ |
| Custom colours, layout & fonts | ✅ | ❌ | ✅ | ✅ |
| Section timings | ✅ | ❌ | ✅ | ✅ |
| Badges shown on menu | 12 | 3 | 12 | 12 |
| Extra menu languages | 3 | 0 | 1 | 3 |
| 3D/AR branding, spotlight, 'Goes well with' | ✅ | ❌ | ✅ | ✅ |
| Customer buttons | All | Rate us only | All | All |
| Branded QR | ✅ | ❌ (plain) | ✅ | ✅ |
| Menu web address | ✅ | ❌ | ❌ | ✅ |
| Offers & happy hour | ✅ | ❌ | ✅ | ✅ |
| My plate | ✅ | ❌ | ✅ | ✅ |
| Analytics, weekly report, AI tools, Today, Staff, Customers | ✅ | ✅ | ✅ | ✅ |

Other numbers: trial 30 days · grace after a plan ends 7 days · rep-published unpaid window 7 days · plan cards also list *WhatsApp & Instagram buttons* (Signature+) and *AR menu on your website*, *per-dish analytics*, *priority support* (MasterChef). These four are sales copy only; the app does not enforce them yet.

## Switches that hide or show features

| Switch | Where it is set | What it controls |
|---|---|---|
| `appearanceEnabled` | Remote config (client config) | Shows all customization screens (Themes, Badges, Languages, Spotlight, Menu web address…) |
| `subscriptionGatesEnabled` | Remote config | Makes the server enforce plan limits at publish ('held back'). Off = everything allowed on the server. The app still asks for a plan at Publish. |
| `SUBSCRIPTION_TESTING_PRICES` | API env | Shows ₹3 / ₹5 / ₹7 test prices with a 'TEST PRICING' banner |
| `WEEKLY_REPORTS_ENABLED` | API env | Turns the Monday weekly report on |
| `AI_API_KEY` | API env | Shows the AI buttons (import menu, descriptions, write description) |
| `MENU_SUBDOMAIN_BASE + DNS` | API env + DNS | Makes 'Menu web address' work |

## Known limits: don't report these as bugs

- **iPhone AR:** iPhone customers get the 3D viewer, not room placement, on the public menu.
- **Screenshot blocking on the QR screen** works on Android only (iOS and web cannot block screenshots).
- **Share link button** is hidden on web; Copy and Open work.
- **Staff access is not plan-gated**, and Managers cannot do full dish editing (Today screen only).
- **Rep standee assignment is advisory:** any rep can activate any free code. This is intentional.
- **Rep-published unpaid page goes fully dark** after 7 days, and its banner is visible to diners. Both were chosen on purpose.
- **3D spin videos** (customization stage 15) are deferred and not built.
- **Not built yet:** WhatsApp delivery of the weekly report, bulk WhatsApp sends, Hindi PDF menus, rep-side badge/diet editor, Mirage 'Our other branches' list, remembering the selected outlet after an app restart.
- **Printable PDF menu** was removed on purpose (replaced by Appearance & Theme in the menu).

## How to give feedback

1. Open **FEATURE-SHEET.csv** in Excel, or import it into a shared Google Sheet (File → Import → Upload).
2. For each row you test, fill in **Status** (`Pass` / `Fail` / `Blocked` / `Not tested`), **Tested on** (APK / Web + phone model), **Tester**, **Date**, **Feedback / bug details** and **Severity** (`Critical` / `High` / `Medium` / `Low` / `Suggestion`).
3. For a failure, write the steps you took, what you expected (copy it from *Expected result*) and what you saw. Attach a screenshot and quote the **ID**.
4. Ideas and UI suggestions are welcome too. Use Severity `Suggestion`.
5. Test accounts per role (User / Rep / Artist / Admin) are shared by the dev team separately. Don't put phone numbers in the sheet.
