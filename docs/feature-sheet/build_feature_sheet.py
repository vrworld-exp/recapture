# docs/feature-sheet/build_feature_sheet.py
#
# The ONE source for the ReCapture feature sheet. Running it writes:
#   FEATURE-SHEET.md   - the readable version (page-wise, with access tables + detail cards)
#   FEATURE-SHEET.csv  - the testing sheet (one row per feature + feedback columns),
#                        opens directly in Excel / Google Sheets
#
# Edit the FEATURES list below, then run:   python build_feature_sheet.py
# Never hand-edit the .md or .csv - they are regenerated and edits are lost.

import csv
import os
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
AS_OF = "2026-10-02"
BRANCH = "feature/more-customize-for-mirage"

# ── Who can use it ──────────────────────────────────────────────────────────
# Access is a 9-character string, one character per user type, in this order:
ROLES = [
    ("U", "User", "Logged-in user with no paid plan (new account, or plan ended)"),
    ("T", "Taste", "Logged-in owner on the Taste plan (1st plan)"),
    ("S", "Signature", "Logged-in owner on the Signature plan (2nd plan, 'Pro')"),
    ("M", "MasterChef", "Logged-in owner on the MasterChef plan (3rd plan, 'Premium')"),
    ("Ad", "Admin", "ADMIN role"),
    ("Ar", "Artist", "MODEL_ARTIST role (3D model artist / staff)"),
    ("R", "Sales rep", "SALES_REP role"),
    ("H", "Staff helper", "Someone an owner added on the Staff screen (Manager or Team member). This column is what they can do on THAT restaurant. On their own account they are a normal User"),
    ("C", "Customer", "Diner who scans the QR. No login, no app - uses the public menu page"),
]
SYMBOL = {"y": "✅", "p": "🔒", "n": "❌"}

# Shorthands for common access patterns (order: U T S M Ad Ar R H C)
EVERYONE_IN_APP = "yyyyyyyyn"   # any signed-in account
OWNER = "yyyyyyynn"             # any signed-in account, on their OWN catalog (helpers: no)
SIG_PLUS = "ppyyyyynn"          # Signature and MasterChef (held back on Taste / no plan)
MC_ONLY = "pppyyyynn"           # MasterChef only
STAFF_ONLY = "nnnnyynnn"        # Artist + Admin
REP_PLUS = "nnnnyyynn"          # Sales rep, Artist, Admin (roles are inclusive upward)
ADMIN_ONLY = "nnnnynnnn"
PUBLIC = "nnnnnnnny"            # customer-facing menu page

FEATURES = []
SECTIONS = []


def section(code, title, where, intro):
    SECTIONS.append({"code": code, "title": title, "where": where, "intro": intro})


def f(name, where, access, what, how, expect, notes="", platform="APK · Web", switch=""):
    assert len(access) == 9, (name, access)
    sec = SECTIONS[-1]
    n = sum(1 for x in FEATURES if x["sec"] == sec["code"]) + 1
    FEATURES.append({
        "sec": sec["code"], "id": f"{sec['code']}-{n:02d}", "name": name, "where": where,
        "access": access, "what": what, "how": how, "expect": expect, "notes": notes,
        "platform": platform, "switch": switch,
    })


# ════════════════════════════════════════════════════════════════════════════
# 1. SIGN-IN
# ════════════════════════════════════════════════════════════════════════════
section("AUTH", "Sign-in & app start", "Splash → Login → OTP",
        "How anyone gets into the app. There are no passwords: sign-in is a one-time code (OTP).")

f("Splash screen", "App launch", EVERYONE_IN_APP,
  "First screen while the app loads ('Preparing capture tools…'). Decides whether to show Login or go straight to Home.",
  "1. Kill the app.\n2. Open it again.",
  "Signed in → lands on Projects (Home). Signed out → lands on Login.")
f("Log in with phone number", "Login screen → Phone tab", "yyyyyyyyn",
  "Sign in with a mobile number. A one-time code is sent and typed on the next screen.",
  "1. Open the app signed out.\n2. Choose Phone, enter a 10-digit number.\n3. Tap Send OTP.",
  "OTP screen opens showing 'Sent to <number>'. Too many tries shows 'Too many attempts — try again in Ns'.",
  notes="Depends on the SMS provider being on. If SMS is not running, test with Email.")
f("Log in with email", "Login screen → Email tab", "yyyyyyyyn",
  "Same as phone sign-in, but the code is sent by email.",
  "1. Choose Email.\n2. Enter an email address.\n3. Tap Send OTP.",
  "Code arrives by email; OTP screen opens.")
f("Enter / resend OTP", "OTP screen", "yyyyyyyyn",
  "Type the code to finish signing in. 'Resend code' unlocks after a countdown. A wrong code says 'Incorrect code, try again'.",
  "1. Type a wrong code → Verify.\n2. Type the right code → Verify.\n3. Wait for the timer and tap Resend code.",
  "Wrong code is refused with a message; right code opens Home. The code locks after 5 wrong guesses.",
  notes="Dev/test builds show the code on screen in a 'FOR DEV ONLY' box. This must NOT be visible in a production build - please report it if you see it there.")
f("Stay signed in", "Whole app", EVERYONE_IN_APP,
  "The session is remembered. Closing the app or the browser tab does not sign you out.",
  "1. Sign in.\n2. Close the app for a few hours (or a day).\n3. Reopen.",
  "Still signed in, no OTP asked.")
f("Protected pages", "Any deep link", EVERYONE_IN_APP,
  "Pages that need an account cannot be opened signed out; pages for a role (Rep / Admin) cannot be opened without that role.",
  "1. Signed out, open a deep link such as /catalog on web.\n2. As a plain User, try /rep/catalogs or /admin/standees.",
  "Signed out → sent to Login. Wrong role → sent back to a normal page, never a broken screen.",
  platform="Web (deep links), APK")

# ════════════════════════════════════════════════════════════════════════════
# 2. HOME
# ════════════════════════════════════════════════════════════════════════════
section("HOME", "Home page (Projects)", "Opens after sign-in",
        "The Projects list is the app's home. Each project is one object being photographed and turned into a 3D model. "
        "The top bar has the notification bell, the Catalog button and the profile picture.")

f("Projects list", "Home", EVERYONE_IN_APP,
  "Every project you created, newest first, with its status (Uploading…, Processing…, ready) and 'Updated <time ago>'.",
  "1. Open Home.\n2. Pull down to refresh.",
  "Your projects appear as cards. A fresh account sees an empty state with a button to start the first capture.",
  notes="Loading text must not mention API names (it should read like 'Fetching your projects').")
f("Top bar: bell, Catalog, profile picture", "Home → top right", EVERYONE_IN_APP,
  "Bell = notifications (with unread count). Catalog = your storefront. Avatar = your profile (shows your photo if you set one).",
  "Tap each of the three icons.",
  "Bell → Notifications; Catalog → Catalog page; Avatar → Profile.")
f("Create a project (+ button)", "Home → red + button", EVERYONE_IN_APP,
  "Starts a new project. First asks HOW you want to capture: Full Capture, Maya AI Capture, or (staff only) Upload photos.",
  "1. Tap +.\n2. Pick a capture mode → Continue.\n3. Enter project name and object size → Create & Continue.",
  "Dismissing the sheet goes nowhere. After Create, the capture checklist opens.",
  notes="'Upload photos' is shown only to Artist and Admin.")
f("Project card actions", "Home → a project card", EVERYONE_IN_APP,
  "Buttons change with the project's state: Resume (unfinished capture), Retry (failed upload), Generate 3D model, Models, View.",
  "Use projects in different states and tap the button shown on each.",
  "Each button opens the right screen; a project with a ready model shows 'Models' instead of 'Generate 3D model'.")
f("Rename / delete a project", "Project card → ⋮ (Project options)", EVERYONE_IN_APP,
  "Rename the project, or delete it.",
  "1. Tap ⋮ on a card.\n2. Rename, save.\n3. Delete another project.",
  "Name updates at once; deleted project disappears from the list.")
f("My projects / Live projects tabs", "Home → tabs at top", STAFF_ONLY,
  "Staff see two tabs: their own projects, and 'Live projects' - finished uploads from ALL users, for model work.",
  "Sign in as Artist or Admin and switch tabs.",
  "Normal users see no tabs. Live tab has no + button (read-only list).",
  notes="Details of the Live tab are in section ART (Model Artist / staff tools).")

# ════════════════════════════════════════════════════════════════════════════
# 3. CAPTURE
# ════════════════════════════════════════════════════════════════════════════
section("CAP", "Inside a project: 3D capture flow", "Home → + → capture screens",
        "The guided camera flow that photographs an object from all sides so a 3D model can be built.")

f("Full Capture (48 photos)", "+ → Full Capture", EVERYONE_IN_APP,
  "Highest quality. 48 photos in rings around the object (16/16/16 when the bottom can be shot, 24/24 when it cannot). The app takes shots automatically as you walk round.",
  "1. + → Full Capture → create project.\n2. Follow the levels A → B → C.",
  "All rings complete, summary screen shows 48 photos.",
  platform="APK (phone camera). Web: please verify")
f("Maya AI Capture (6 photos)", "+ → Maya AI Capture", EVERYONE_IN_APP,
  "Fast mode: one ring of 6 photos, about a minute. The 3D model starts building automatically after upload.",
  "1. + → Maya AI Capture.\n2. Take 6 photos in one circle.",
  "Upload starts, then the model builds on its own without pressing Generate.",
  platform="APK. Web: please verify")
f("Pre-capture checklist", "Before the camera opens", EVERYONE_IN_APP,
  "Tick each preparation item (light, clear background…) and answer 'Can you photograph the bottom?' - this picks the ring layout.",
  "Try Start before ticking everything, then tick all.",
  "Start stays disabled until every required item is ticked.")
f("Camera permission screen", "Before the camera opens", EVERYONE_IN_APP,
  "Explains and asks for camera / motion permission. Handles 'denied' and 'denied forever' (opens phone settings).",
  "Deny the permission once, then allow it.",
  "Clear explanation, a way to retry, and a link to settings when blocked.",
  platform="APK")
f("Level intros (A, B, C)", "Between rings", EVERYONE_IN_APP,
  "Before each ring a short screen explains the angle to hold (eye level, from above, from below).",
  "Go through a Full Capture.", "Each level shows its intro before the camera.")
f("Live coaching / quality gate", "Camera screen", EVERYONE_IN_APP,
  "The app refuses blurry, too-dark or shaky photos and tells you to tilt up/down when the angle is wrong - as it happens.",
  "Shake the phone, cover the lens, tilt far down while capturing.",
  "Bad shots are rejected with a clear on-screen message; good ones are counted.",
  platform="APK")
f("Review grid & retake", "After each ring", EVERYONE_IN_APP,
  "Grid of the photos just taken. Tap any one to retake it.",
  "Finish a ring, open a photo, retake it.", "Only that one photo is replaced.")
f("Cancel / resume a capture", "Camera → back", EVERYONE_IN_APP,
  "Leaving mid-capture asks to confirm. The project keeps its progress and shows 'Resume' on Home.",
  "Leave halfway, go Home, tap Resume.", "Capture continues from where you stopped.")
f("Capture summary", "End of capture", EVERYONE_IN_APP,
  "Totals per ring before upload; blocks upload if a ring is incomplete (Full mode offers remedies).",
  "Finish a capture.", "Summary shows counts; Upload button available when complete.")

# ════════════════════════════════════════════════════════════════════════════
# 4. UPLOAD & MODELS
# ════════════════════════════════════════════════════════════════════════════
section("MODEL", "Inside a project: upload, 3D model, AR", "After capture / Project card",
        "What happens after the photos are taken: upload, model building, viewing and improving the model.")

f("Background upload", "Uploading screen", EVERYONE_IN_APP,
  "Photos upload while you use other apps. Losing signal pauses; signal back resumes.",
  "Start an upload, switch to another app, turn mobile data off and on.",
  "Upload continues/resumes and completes without starting over.",
  platform="APK (background). Web: tab must stay open")
f("Upload failed → retry", "Upload failed screen / card Retry", EVERYONE_IN_APP,
  "A failed upload explains why and offers Retry.",
  "Turn on airplane mode during upload, then turn it off and Retry.", "Upload finishes after Retry.")
f("Generate 3D model", "Project card → Generate 3D model", EVERYONE_IN_APP,
  "The server picks the best photos and starts building the model. A full screen explains what was decided and shows progress.",
  "On a finished capture, tap Generate 3D model.",
  "Build screen shows progress; you can leave and come back. A refusal is explained in plain words.",
  notes="Owners have a daily limit on generations.")
f("Model history (Models)", "Project card → Models", EVERYONE_IN_APP,
  "One project can have several models (first try, new versions, optimized copy). All are listed, not just the newest.",
  "Open Models on a project with 2+ models.", "Every version is listed with its status.")
f("Create a new version", "Model viewer / Models → Create a new version", EVERYONE_IN_APP,
  "Builds a fresh model from the same capture when the first one came out wrong.",
  "Open a model → Create a new version.", "A new entry appears in Models and builds.")
f("View 3D model", "Models → open a model", EVERYONE_IN_APP,
  "Spin and zoom the model on screen.",
  "Open any ready model.", "Model loads and can be rotated.")
f("View in AR (place in room)", "Model viewer → AR", EVERYONE_IN_APP,
  "Place the model on your real table through the camera.",
  "Open a model on an AR-capable phone → View in AR.",
  "Model appears in the room at real size. On desktop browser the AR button is hidden.",
  platform="APK · mobile Web (AR-capable phones)")
f("Optimize model", "Models → Optimize", EVERYONE_IN_APP,
  "Makes a smaller, faster-loading copy for customers' phones. Shows as its own entry ('Optimized for fast loading').",
  "Tap Optimize on a large model.", "A smaller version appears beside the original.")
f("Export model (GLB / USDZ)", "Model viewer → Export model", EVERYONE_IN_APP,
  "Download the model file: GLB (Blender, Unity, web) or USDZ (iPhone Quick Look).",
  "Export both formats.", "Files download and open in a 3D viewer.")

# ════════════════════════════════════════════════════════════════════════════
# 5. CATALOG MAIN
# ════════════════════════════════════════════════════════════════════════════
section("CAT", "Catalog page (main screen)", "Home → Catalog button",
        "The catalog is the restaurant's storefront - the menu customers open when they scan the QR. "
        "Everything here is a DRAFT until Publish is pressed. One account = one catalog (plus branches, see TEAM-06).")

f("Create catalog", "Catalog → empty state → Create catalog", OWNER,
  "First-time setup: name the catalog. The public link created at first publish never changes after that.",
  "New account → Catalog → Create catalog → enter name.",
  "Catalog screen appears with 0 products, status Draft.")
f("Catalog header & status chips", "Catalog → top card", OWNER,
  "Shows name, business name, status (Draft / Live / Offline), 'Draft changes not yet live', 'Publishing…', plan chip, and product/category counts.",
  "Edit any product after publishing.", "'Draft changes not yet live' appears, and clears after the next publish.")
f("Main buttons: Publish, Preview, Analytics, QR code, Download QR/standee", "Catalog → header buttons", OWNER,
  "The five main actions. 'QR code' shows once the catalog has a public link; 'Download QR/standee' only while it is Live.",
  "Check each button with a never-published, a live and an offline catalog.",
  "Buttons appear/disappear by state exactly as described.")
f("Edit menu (⋮ More)", "Catalog → ⋮", OWNER,
  "Menu with: Languages & translations, Spotlight & customer buttons, Offers & happy hour, My plate, Today: stock & prices, Staff, "
  "Outlets & branches, Themes & Colours, Import menu from photos, AI descriptions, Customers, Order & booking links, Menu web address, Delete catalog.",
  "Open ⋮ and tap each item.",
  "Each opens its screen. Items behind a switch are hidden when the switch is off (see Notes).",
  notes="Hidden until 'appearanceEnabled' is on: Languages, Spotlight, Themes & Colours, Menu web address, palette & badge icons. "
        "Hidden until the AI key is set: Import menu, AI descriptions. The old 'Printable menu' option has been removed - report it if you still see it.")
f("Payment banners on the catalog", "Catalog → banner under header", OWNER,
  "Shows plan problems with a button: 'Pay now' (payment due / grace), 'Pay to switch it back on' (page switched off), 'Restore 3D' (3D paused).",
  "Use catalogs in each state (pending payment, grace, paused, switched off).",
  "Correct banner and button per state; the button opens Subscription.")
f("Product grid", "Catalog → Products", OWNER,
  "All products as cards: picture, price, 3D or Image only, Out of stock, Archived.",
  "Open a catalog with 10+ products, scroll, Load more.", "Cards show the right badges and price.")
f("Search, filter, sort", "Catalog → Products → search / Show / Sort", OWNER,
  "Search by name; filter by category, type (3D / image) and status; sort by Menu order, Name A–Z, Newest, Oldest, Price.",
  "Combine a search with a filter, then Clear filters.", "List narrows correctly; empty result says 'No products match'.")
f("Select several (bulk actions)", "Catalog → Select", OWNER,
  "Pick many products and Archive, Delete or Move to category in one go. Failed ones stay selected with 'Retry failed'.",
  "Select 3 products → Move to category; then Archive them.", "All 3 move/archive; a toast confirms.")
f("Delete catalog", "Catalog → ⋮ → Delete catalog", "yyyyyyynn",
  "Deletes the catalog AND its public page. The only action that gives up the QR link. You must type the catalog name.",
  "Use a test catalog only. Type a wrong name, then the right one.",
  "Wrong name keeps the button disabled; right name deletes and returns to the empty state.",
  notes="Destructive - test on a throw-away catalog.")
f("Restaurants I help run (helper entry)", "Catalog → empty state", "nnnnnnnyn",
  "If someone added you as staff and you have no catalog of your own, the Catalog page shows 'Restaurants I help run' (and 'Create my own catalog').",
  "Have an owner add your number on Staff, sign in with that number, open Catalog.",
  "Opens the list of restaurants you help with (see TEAM-05).")

# ════════════════════════════════════════════════════════════════════════════
# 6. PRODUCTS
# ════════════════════════════════════════════════════════════════════════════
section("PROD", "Inside catalog: products (dishes)", "Catalog → Add product / tap a product",
        "Adding and editing the items on the menu.")

f("Add product from a finished capture (3D)", "Catalog → Add product → From a finished capture", OWNER,
  "Pick one of your captures, then pick exactly which model version to use (preview each first).",
  "Add product → From a finished capture → pick capture → pick model → name, price → Add product.",
  "Product appears with a 3D badge and an automatic thumbnail.",
  notes="3D dishes count toward the plan cap: Trial 10, Taste 10, Signature 15, MasterChef 30.")
f("Add product as image only", "Add product → Image only — no AR", OWNER,
  "A photo, name and price is a full product, with no 3D/AR. JPEG, PNG or WebP up to 5 MB.",
  "Add product → Image only → choose photo → name → Add.", "Product shows 'Image only'. Unlimited on every plan.")
f("Product details: name, price, description, category, featured, stock", "Add / Edit product", OWNER,
  "Basic fields. Price optional ('No price set'). Featured sorts first. In/Out of stock.",
  "Edit each field and Save changes.",
  "Toast confirms; 'This is a draft edit. Customers see it after you publish.'")
f("Veg / non-veg / none mark", "Edit product → Veg / non-veg", OWNER,
  "Choose green veg mark, red non-veg mark, or no mark.",
  "Set each of the three values and publish.", "The public menu shows the chosen mark (or none).")
f("Tags", "Edit product → Tags", OWNER,
  "Private labels for your own organising (max 20). Not shown to customers.",
  "Add a few tags.", "Saved; public menu does not show them.")
f("Diet & allergens, spice, serves, prep time", "Edit product → Diet & allergens", OWNER,
  "Suitable for (Vegan, Jain, Gluten-free…), Contains (allergens), spice level, serves, minutes. Conflicts (e.g. Vegan + Dairy) are refused.",
  "Fill the section; try Vegan with Dairy.",
  "Conflict shows an error; valid details appear on the public dish and power diet filters.")
f("Badges on a dish", "Edit product → Badges", OWNER,
  "Put badges from your badge library (Bestseller, Chef's special…) on a dish. The menu card shows the first two.",
  "Create badges first (LOOK-08), then tick 2–3 on a dish.", "Dish card on the menu shows two badges.",
  notes="How many badges show depends on plan: Taste 3, Signature/MasterChef 12.")
f("Goes well with (pairings)", "Edit product → Goes well with", SIG_PLUS,
  "Suggest up to 4 dishes to have with this one.",
  "Pick 2 dishes → Save → publish.", "Dish page on the menu shows 'Goes well with'.",
  notes="Saved on every plan; shown on the menu only on Signature+ (held back on Taste).",
  switch="appearanceEnabled")
f("Other languages (dish translation)", "Edit product → Other languages", SIG_PLUS,
  "Type the dish name/description in each extra menu language.",
  "Add a language (LOOK-09) then translate one dish.", "Switching language on the menu shows the translation.",
  switch="appearanceEnabled")
f("Change 3D model", "Edit product → Change 3D model", OWNER,
  "Point the product at a different model version from the same capture, after previewing it.",
  "Change model → pick another → Save → publish.", "Public dish shows the new model; the QR is unaffected.")
f("Replace photo / switch to 3D", "Edit product → Replace photo / Use a 3D model instead", OWNER,
  "Swap the picture, or convert an image-only product into a 3D one.",
  "Replace a photo; convert an image product to 3D.", "New picture/3D shows after publish.",
  notes="Converting restarts that dish's analytics history on the public side.")
f("Duplicate product", "Edit product → Duplicate product", OWNER,
  "Copies a product for variants; the copy is renamed automatically.",
  "Duplicate a product.", "'Duplicated as \"<name> (2)\"' and the copy appears.")
f("Archive / restore / delete permanently", "Edit product or card menu", OWNER,
  "Archive hides a product without losing it; Restore brings it back; Delete permanently needs typing the name.",
  "Archive → Restore → Delete another one.", "Archived product leaves the menu at next publish; delete is permanent.")
f("AI: write description / enhance photo", "Edit product → ✨ buttons", OWNER,
  "'Write description' gives AI suggestions to pick from. 'Enhance photo' straightens, crops and brightens (Original vs Enhanced).",
  "Tap Write description → pick one. Tap Enhance photo → Use enhanced.",
  "Text filled in; enhanced photo saved, shows after publish.",
  switch="AI_API_KEY (hidden when not set)")

# ════════════════════════════════════════════════════════════════════════════
# 7. CATEGORIES
# ════════════════════════════════════════════════════════════════════════════
section("SEC", "Inside catalog: categories (menu sections)", "Catalog → Categories",
        "Grouping dishes into sections such as Starters, Mains, Desserts.")

f("Create / rename / delete category", "Categories → New category / Category options", OWNER,
  "Manage sections. Deleting a non-empty one asks where its products should move ('Move and delete').",
  "Create 3, rename 1, delete 1 that has products.", "Products move to the chosen section; nothing is lost.")
f("Drag to reorder categories", "Categories → drag handle", OWNER,
  "Order sections appear on the public menu.", "Drag a section to the top.", "'Category order saved.'; menu order matches after publish.")
f("Move products between categories", "Categories → a category → Add products / Move to…", OWNER,
  "Add products into a section or move selected ones to another.", "Move 2 products.", "They now show under the new section.")
f("Uncategorized bucket", "Categories", OWNER,
  "Products with no section land here. It is always last and cannot be renamed or deleted.",
  "Delete a section and choose Uncategorized.", "Products appear under Uncategorized.")
f("Section timings (Available times)", "Categories → Category options → Available times", SIG_PLUS,
  "Serve a section only at certain hours (e.g. Breakfast 7–11). Outside: hide it, or show it greyed with its hours. India time.",
  "Set Breakfast 07:00–11:00, publish, open menu after 11.",
  "Section hidden or greyed outside the window.",
  notes="Saved on every plan; shown only on Signature+.")

# ════════════════════════════════════════════════════════════════════════════
# 8. LOOK & BRANDING
# ════════════════════════════════════════════════════════════════════════════
section("LOOK", "Inside catalog: look, branding & restaurant info", "Catalog → header icons / ⋮ / Business profile",
        "Make the menu look like the restaurant's own. Rule for all of these: you can always SAVE; the publish only sends what the plan covers, "
        "and the publish screen lists the rest as 'Held back on your plan'. Upgrading and republishing restores it - nothing is deleted.")

f("Business profile", "Catalog → badge icon (Business profile)", OWNER,
  "Storefront name, logo, cover image, legal name, phone, WhatsApp, email, address, website, social links. The screen marks which fields reach the public page.",
  "Fill every field, upload logo and cover (16:9), Save profile, publish.",
  "Public page shows logo, cover banner and the fields marked 'Shown on your public page'.",
  notes="Rep: also for restaurants they activated (Restaurant details).")
f("Themes & Colours (Appearance)", "Catalog → palette icon, or ⋮ → Themes & Colours", OWNER,
  "Pick a theme preset; see a live phone preview; Save look; publish.",
  "Choose a different preset → Save look → Publish → open the public menu.",
  "Public menu uses the new theme after publish.",
  notes="Rep: also for restaurants they activated.", switch="appearanceEnabled")
f("Custom primary & accent colours", "Appearance → Customize colours", SIG_PLUS,
  "Your own brand colours (hex). Colours with poor contrast are refused.",
  "Enter a primary and accent → Save → Publish.",
  "Signature+: menu uses them. Taste/no plan: publish lists 'Custom colours' as held back.", switch="appearanceEnabled")
f("Layout & fonts", "Appearance → Layout / Fonts", SIG_PLUS,
  "Card layout Grid / List / Large and curated font pairs.",
  "Switch to List and a new font → publish.", "Menu layout and font change (Signature+).", switch="appearanceEnabled")
f("Diet filters on the menu", "Appearance → Diet filters", OWNER,
  "Lets customers filter by Veg only, Jain, Vegan, Gluten-free, No nuts (only filters your dishes actually have).",
  "Turn on, publish, use filter on the menu.", "Filter chips appear and work.", switch="appearanceEnabled")
f("Opening hours & holidays", "Business profile → Opening hours & holidays", OWNER,
  "Weekly time slots ('Same as Monday' to copy), holidays, and 'Show \"Open now\" on the menu'. India time.",
  "Set hours, add a holiday, publish, check the menu at different times.",
  "Menu shows 'Open · closes 11 pm' / 'Closed' correctly.",
  notes="Rep: also for restaurants they activated.")
f("Announcement strip", "Catalog → Announcement", OWNER,
  "One-line strip on the menu (info, offer or alert) with optional link and start/end dates.",
  "Save 'Diwali special — 20% off' with an end date, publish.",
  "Strip shows while live; disappears after the end date by itself.")
f("Badge library", "Catalog → tag icon (Badges)", OWNER,
  "Design up to 12 badges once (label, colour) and use them on any dish. Starter set provided.",
  "Create 4 badges → Save badges → put them on dishes.",
  "Taste shows the first 3 on the menu; Signature/MasterChef show all 12.", switch="appearanceEnabled")
f("Menu languages", "⋮ → Languages & translations → Choose languages", SIG_PLUS,
  "Main language plus extra languages from 9 Indian languages. Customers get a language switcher.",
  "Add Hindi → translate → publish → switch language on the menu.",
  "Taste: 0 extra languages; Signature: 1; MasterChef: 3. Untranslated text falls back to the main language.",
  switch="appearanceEnabled")
f("Translations editor", "⋮ → Languages & translations", SIG_PLUS,
  "Type translations for every dish, section, badge and the announcement, with progress and 'Only show what still needs translating'.",
  "Translate 2 dishes and a section.", "Progress updates; menu shows the translations after publish.",
  notes="No machine translation - the owner types everything.", switch="appearanceEnabled")
f("3D & AR style", "Appearance → 3D & AR style", SIG_PLUS,
  "Branding on the 3D viewer: logo while loading, logo watermark, surface under the dish, dish name & price.",
  "Turn on watermark → Save → publish → open a 3D dish.", "Viewer shows the logo/watermark (Signature+).",
  notes="Needs a logo on the Business profile.", switch="appearanceEnabled")
f("Branded QR style", "QR code → QR style", SIG_PLUS,
  "QR colours (Classic, Charcoal, Navy, Forest, Wine, Espresso), your logo in the centre, frame text, and the standee template.",
  "Pick Navy + logo → Save QR style → download a standee.",
  "Signature+: styled QR. Taste: prints plain black & white. A styled code that would not scan is replaced by the plain one automatically.",
  notes="Always test a printed code with 2–3 phones.", switch="appearanceEnabled")
f("Menu web address", "⋮ → Menu web address", MC_ONLY,
  "An easy address like yourname.<menu domain> for Instagram/WhatsApp. The printed QR link never changes.",
  "Enter 'bluecafe' → Save address → publish → open the address.",
  "MasterChef: the address opens the menu. Others: held back.",
  switch="appearanceEnabled + MENU_SUBDOMAIN_BASE (DNS)")

# ════════════════════════════════════════════════════════════════════════════
# 9. ENGAGEMENT & VALUE
# ════════════════════════════════════════════════════════════════════════════
section("GROW", "Inside catalog: customer engagement & business value", "Catalog → ⋮ / Analytics",
        "Features that help the restaurant sell more and know its customers.")

f("Chef's spotlight carousel", "⋮ → Spotlight & customer buttons → Spotlight", SIG_PLUS,
  "Up to 6 dishes in a carousel at the top of the menu, with an optional title.",
  "Pick 3 dishes → Save spotlight → publish.", "Carousel at top of the menu (Signature+).", switch="appearanceEnabled")
f("Customer buttons", "⋮ → Spotlight & customer buttons → Customer buttons", SIG_PLUS,
  "Rate us (Google review link or Place ID), Order on WhatsApp, Call waiter, Wi-Fi (name + password), Feedback form (1–5 + comment).",
  "Fill all, Save buttons, publish, try each on the menu.",
  "Taste / no plan: only 'Rate us' shows. Signature+: all buttons. Feedback replies appear in Analytics.",
  notes="Review link must be a Google link. WhatsApp buttons need a WhatsApp number on the Business profile.",
  switch="appearanceEnabled")
f("Offers, combos & happy hour", "⋮ → Offers & happy hour", SIG_PLUS,
  "Percent off, rupees off, new price, or combo price - on chosen dishes, sections or the whole menu - with days and time windows. Live preview of prices. Up to 20 active.",
  "Create 'Happy hour 5–7 pm, 20% off drinks' → Save → publish → open menu inside and outside the window.",
  "Inside the window: struck-through prices, offer strip, Offers pill. Outside: normal prices.",
  notes="Swipe an offer left to delete it.")
f("My plate (customer's order list)", "⋮ → My plate", SIG_PLUS,
  "Lets customers tap + on dishes to build a plate, see a total, and 'Show to waiter' or send on WhatsApp. Option to hide the running total.",
  "Turn on, publish, build a plate on the menu.",
  "Plate works on the menu (Signature+). Stats appear in Analytics and the weekly report.",
  notes="ON by default - shows at the restaurant's next publish.")
f("Order & booking links", "⋮ → Order & booking links", OWNER,
  "Zomato / Swiggy 'Order online' chips, a booking page link, and phone/WhatsApp number for 'Book a table'.",
  "Fill Zomato link and booking link → Save links → publish.",
  "Menu shows the chips/button; wrong links (not https://, wrong site) are refused.")
f("Customer list (WhatsApp offers sign-ups)", "⋮ → Customers", "yyyyyyynn",
  "Customers who joined from the menu (with consent). Search, birthdays this week, open WhatsApp chat with a message, mark opted out, delete, Export CSV.",
  "Sign up from the public menu, then open Customers.",
  "The person appears; CSV contains only subscribed customers.",
  notes="Owner only - reps and helpers cannot see customers. Follows DPDP consent rules.")
f("Analytics", "Catalog → Analytics", OWNER,
  "Catalog opens, sessions, product views, AR launches, contact clicks, browse taps, QR scans vs direct links; chart or table by day; date range; top products.",
  "Scan the QR a few times and open dishes, then check Analytics.",
  "Numbers rise; comparison with the previous period shown.",
  notes="Plan card lists 'Per-dish view analytics' for MasterChef, but today every plan sees the same analytics.")
f("Weekly report", "Analytics → Weekly reports (or Monday notification)", OWNER,
  "Every Monday: menu views, visitors, QR scans, AR views, top dishes, busiest hours, daily chart, plates built, offer views and up to 2 tips. Share as image.",
  "On a test restaurant with reports switched on, open the latest report.",
  "Report for last week; 'Share as image' produces a picture.",
  notes="Reps see reports of their restaurants read-only.", switch="WEEKLY_REPORTS_ENABLED")

# ════════════════════════════════════════════════════════════════════════════
# 10. AI
# ════════════════════════════════════════════════════════════════════════════
section("AI", "Inside catalog: AI tools", "Catalog → ⋮",
        "AI helpers. All of them are hidden when the server has no AI key. A hard monthly budget (₹2,000 across all restaurants) and 5 imports/day per restaurant apply.")

f("Import menu from photos / PDF", "⋮ → Import menu from photos", OWNER,
  "Photograph a paper menu or pick a PDF (up to 10 pages, 20 MB each). AI reads sections, dishes and prices into a draft you check, tick and add. 'Undo this import' afterwards.",
  "Take photos of a printed menu → Read my menu → check → Add N dishes → then Undo.",
  "Dishes added as photo-less drafts; Undo removes them (keeps ones you already edited).",
  notes="Rep: also on restaurants they activated.", switch="AI_API_KEY")
f("Bulk AI descriptions", "⋮ → AI descriptions", OWNER,
  "Writes descriptions for every dish missing one, in a tone: Casual, Premium or Fun. You pick which to save.",
  "Choose Premium → Write N descriptions → Save.",
  "Descriptions saved; 'The AI budget for this month is used up' when the cap is hit.", switch="AI_API_KEY")

# ════════════════════════════════════════════════════════════════════════════
# 11. TEAM & DAILY OPS
# ════════════════════════════════════════════════════════════════════════════
section("TEAM", "Inside catalog: daily edits, staff & branches", "Catalog → ⋮",
        "Quick day-to-day changes, letting staff help, and running more than one outlet.")

f("Today: stock & prices", "⋮ → Today: stock & prices", "yyyyyyyyn",
  "Every dish in one list: stock switch, price, search, 'sold out only'. Long-press for 'Sold out until tomorrow' (back at 5 am). Changes go in one batch; 'Publish now'.",
  "Mark 2 dishes sold out, change 1 price → Publish now.",
  "'Saved and publishing — live in a few seconds.' Menu shows sold out; the 'until tomorrow' dish returns at 5 am.",
  notes="Staff helper: Team member = stock + publish; Manager = stock + prices + publish.")
f("Bulk price change", "Today → Select → Change prices", "yyyyyyypn",
  "Change many prices by percent or flat amount, with rounding, preview and a 7-day Undo.",
  "Select a section → +10% → Preview → Apply → Undo.",
  "Prices change and then revert with Undo.", notes="Helper: Manager only.")
f("Recent changes log", "Today → Recent changes", "yyyyyyyyn",
  "Who changed what (owner or which staff member). Kept 90 days.",
  "Make changes as owner and as a helper.", "Both appear with the right name.")
f("Staff (invite helpers)", "⋮ → Staff", "yyyyyyynn",
  "Add up to 5 people by mobile number as Manager or Team member. Remove anyone; they lose access at once. Helpers never see billing.",
  "Add a number as Team member → sign in with it → check access → remove it.",
  "Helper sees the restaurant; after removal access stops immediately.",
  notes="Not plan-gated.")
f("Helper's view: Restaurants I help run", "Catalog → Restaurants I help run (/staff)", "nnnnnnnyn",
  "A helper's list of restaurants they were added to; opens that restaurant's Today screen with only their permissions.",
  "Sign in as a helper → open the restaurant.", "Only Today actions allowed; the server refuses anything else.")
f("Outlets & branches", "⋮ → Outlets & branches (or outlet chip)", "yyyyyyynn",
  "One main outlet + up to 10 branches. Each branch has its own page, QR, stock, prices, staff, offers and plan. Menu and look are set once on the main outlet and copy down; a branch can override price/stock ('Reset' to main).",
  "Add branch → switch to it with the outlet chip → change one price there → change the dish on main.",
  "Branch keeps its own price; other main edits arrive automatically. Brand screens are locked on a branch.",
  notes="'Publish all outlets' button is still present (removal requested in learn.txt, not done yet). Each outlet is billed separately.")

# ════════════════════════════════════════════════════════════════════════════
# 12. PREVIEW / PUBLISH / QR
# ════════════════════════════════════════════════════════════════════════════
section("PUB", "Inside catalog: preview, publish, QR & standees", "Catalog → Preview / Publish / QR code",
        "Checking the draft, putting it live, and getting the printed QR.")

f("Preview", "Catalog → Preview", OWNER,
  "Shows the draft exactly the way a customer will see it, before publishing.",
  "Edit a dish, open Preview.", "Preview shows the edit even though it is not live.")
f("Publish checklist", "Catalog → Publish", OWNER,
  "Lists EVERY problem at once in plain words (no products, missing name, dish without photo, duplicate names, still generating…) with one-tap fixes like 'Use \"Lassi (2)\" and publish'.",
  "Create two dishes with the same name and a dish without a photo → Publish.",
  "Both problems listed together; the rename fix works.")
f("Choose a plan at Publish (paywall)", "Publish → plan card", "pyyyyyynn",
  "If the catalog has no plan, Publish shows a plan card first. After paying you come back and the publish starts without a second tap.",
  "New account → build a catalog → Publish.",
  "Plan card appears; after a (test) payment the publish runs.",
  notes="A restaurant set up by a rep can publish before payment - see REP-08.")
f("Publish with live progress", "Publish", OWNER,
  "Runs in the background (you can leave). Each dish shows Synced / Pending / Failed / Never published with a reason.",
  "Publish 10 dishes, leave the screen and come back.", "Dishes turn green one by one; 'Your catalog is live.'")
f("Retry failed only", "Publish → Retry failed", OWNER,
  "If some dishes fail, retry pushes only those.", "Turn network off mid-publish, then Retry failed.", "Only failed ones are re-sent and succeed.")
f("Held back on your plan", "Publish → card", OWNER,
  "Lists customizations your plan does not cover (sent with the standard look). Your choices stay saved.",
  "On Taste, set custom colours and an offer → Publish.",
  "Card lists 'Custom colours needs the Signature plan' etc.; menu shows standard look.",
  switch="subscriptionGatesEnabled")
f("3D dish cap at publish", "Publish", OWNER,
  "If you have more 3D dishes than the plan allows (Trial 10, Taste 10, Signature 15, MasterChef 30), publish asks you to upgrade or switch some to image.",
  "On Taste add 11 3D dishes → Publish.", "Publish explains the cap and offers 'See plans'.")
f("Take catalog offline / back live", "Publish → Take offline", OWNER,
  "Removes the dishes from the public page, but the QR and link keep working. Publishing again brings it back.",
  "Take offline → scan QR → Publish again.", "QR shows the 'not live' message, then the menu again.")
f("Public link: copy, share, open", "Publish / QR screen", OWNER,
  "Copy the permanent link, share it, or open it.",
  "Tap Copy link, Share, Open.", "Link copied/shared/opened. Share button is hidden on web.")
f("QR code (view)", "Catalog → QR code", OWNER,
  "Shows the catalog's permanent QR. It never changes on rename or republish.",
  "Republish after renaming; scan the old QR.", "Old QR still opens the menu.",
  notes="The screen is view-only (screenshots blocked on Android). Downloads go through the counted standee download.")
f("Download QR/standee (counted)", "Catalog → Download QR/standee, or QR → Download in A4 size", "pyyyyyynn",
  "Download A4 standee PDFs (one QR per page). Ask how many (1 to what's left). Each download uses up your plan's standees: Taste 10, Signature 15, MasterChef 30 - one lifetime pool.",
  "Live catalog → Download → choose 2 → check the remaining count.",
  "PDF with 2 standees; remaining count drops by 2; at 0 it says 'Upgrade your plan for more'.",
  notes="Only while the catalog is Live.")
f("Activity / publish history", "Publish", OWNER,
  "What was published when, and what failed.", "Publish twice.", "Both runs listed.")

# ════════════════════════════════════════════════════════════════════════════
# 13. SUBSCRIPTION
# ════════════════════════════════════════════════════════════════════════════
section("SUB", "Subscription & payments (owner)", "Profile → Subscription, or Catalog → Pay now",
        "Plans: Taste ₹1,199/month, Signature ₹1,799/month, MasterChef ₹2,499/month; yearly saves 30%. Free trial 30 days. "
        "In test mode prices show as ₹3 / ₹5 / ₹7 with a 'TEST PRICING' banner.")

f("Your plan (status card)", "Subscription screen → top", OWNER,
  "Current plan, status (Trial, Active, Grace, Paused, Complimentary…), end / renewal date, days left, 3D dish usage, standees, 'See catalog'.",
  "Open with a catalog on each status.", "Card matches the real status and dates.")
f("Plans & compare", "Subscription → Plans", OWNER,
  "The three plans with caps and perks, monthly/yearly switch, 'Save 30% with yearly billing', Upgrade to next tier.",
  "Toggle Monthly/Yearly.", "Prices update correctly; yearly = 12 × monthly − 30%.")
f("Subscribe with autopay (Razorpay)", "Subscription → Continue to <plan>", OWNER,
  "Approve autopay once with UPI, card or net banking; the plan then renews every month/year by itself.",
  "In test pricing mode, subscribe to Taste monthly.",
  "'Payment received — your plan is active.' appears quickly; Autopay is on.",
  platform="APK · iOS · Web (in-app payment)", notes="Use testing prices only.")
f("Turn off autopay", "Subscription → Turn off autopay", OWNER,
  "Stops future renewals; the paid period continues to its end.",
  "Turn off → confirm.", "'Autopay turned off' + notification; plan stays until end date.")
f("Payment history & receipts", "Subscription → Payment history", OWNER,
  "All payments with Download receipt; refunds shown.", "Open after a payment.", "Receipt PDF downloads.")
f("Free trial", "Started by a rep or admin", OWNER,
  "30 days, up to 10 3D dishes, every customization unlocked. One trial per restaurant, ever.",
  "Rep starts a trial (REP-09), owner opens Subscription.", "Shows 'Free trial' with end date.")
f("Grace, pause, payment-due lifecycle", "Catalog banners + notifications", OWNER,
  "Plan ends → 7-day grace (all still works) → 3D paused (photo menu stays live). A rep-published unpaid restaurant has 7 days to pay before the WHOLE page switches off.",
  "Admin can shorten dates on a test catalog to walk through each step.",
  "Correct banner, notification and public page behaviour at each step.",
  notes="A restaurant that has ever paid never loses its photo menu.")

# ════════════════════════════════════════════════════════════════════════════
# 14. PROFILE
# ════════════════════════════════════════════════════════════════════════════
section("PROF", "User profile page", "Home → profile picture",
        "Your own account. Extra rows appear depending on your role.")

f("Profile photo", "Profile → avatar", EVERYONE_IN_APP,
  "Choose, replace or remove a photo (JPG/PNG).", "Upload a photo, then remove it.", "Photo shows on Profile and Home top bar.")
f("Name, contact, role, member since", "Profile", EVERYONE_IN_APP,
  "Edit your display name. See your masked phone/email, your role badge and 'Member since'.",
  "Edit name → Save.", "Name updated everywhere.")
f("Subscription row", "Profile → Subscription", EVERYONE_IN_APP,
  "'Your plan, 3D dish usage and prices' - opens the Subscription screen.", "Tap it.", "Subscription screen opens.")
f("Rep rows: My restaurants, My standees, Published standees", "Profile", REP_PLUS,
  "Shortcuts into the Sales rep area (section REP).", "Sign in as rep, open each row.", "Rows open the rep screens; a plain User never sees them.")
f("Admin rows: Standee inventory, Subscriptions", "Profile", ADMIN_ONLY,
  "'Mint QR codes and send one to a rep' and 'Verify cash payments, comps and who is expiring'.",
  "Sign in as Admin.", "Rows visible only to Admin.")
f("All catalogs (admin)", "Profile → All catalogs", ADMIN_ONLY,
  "Grid (2 per row) of every live catalog with name and icon, search, Load more. Open one to see it like a customer; tap the banner to edit and publish it directly (Publish by admin / Unpublish by admin with a reason).",
  "Admin → All catalogs → open one → edit a dish → Publish by admin.",
  "Change is live on that restaurant's menu.",
  notes="Built and committed on branch feature/subcription-stated-f-noti; NOT yet in feature/more-customize-for-mirage. Test on a build from that branch.")
f("Sign out", "Profile → Sign out", EVERYONE_IN_APP,
  "Ends the session on this device.", "Sign out.", "Back at Login; Back button does not return into the app.")

# ════════════════════════════════════════════════════════════════════════════
# 15. NOTIFICATIONS
# ════════════════════════════════════════════════════════════════════════════
section("NOTI", "Notifications", "Home → bell",
        "In-app feed of updates about payments, activation and the catalog (some also go by SMS).")

f("Notification feed", "Bell → Notifications", EVERYONE_IN_APP,
  "List with unread state, Details, and 'Mark all read'.", "Open feed, open one, Mark all read.", "Unread count on the bell goes to 0.")
f("Subscription notifications", "Feed (+ SMS for some)", EVERYONE_IN_APP,
  "Trial started, payment received, plan ends in N days, autopay renews in N days, menu live — payment due, live menu switches off in N days, 3D paused, "
  "page switched off, deadline extended, 'You have not chosen a plan yet', cash payment awaiting verification, payment not confirmed, autopay on/failed/stopped/turned off, duplicate refunded, comped.",
  "Walk a test catalog through trial → payment → expiry.", "The matching notification appears at each step, once.")
f("Weekly report & menu notifications", "Feed", EVERYONE_IN_APP,
  "Monday 'See report' notification; 'more 3D dishes than your plan covers'; dish turned 3D after a rep's capture.",
  "With weekly reports on, wait for Monday or trigger the job.", "Tapping opens the right screen.")
f("Admin alerts", "Feed", ADMIN_ONLY,
  "Payment problems for admins: chargebacks, duplicate payments, amount mismatch, payments for unknown/deleted catalogs, 'Razorpay webhooks may be disabled'.",
  "Seen only when such a case happens.", "Admin receives it; owners never do.")

# ════════════════════════════════════════════════════════════════════════════
# 16. REP
# ════════════════════════════════════════════════════════════════════════════
section("REP", "Sales rep area", "Profile → My restaurants (/rep)",
        "A rep walks into a restaurant with pre-printed QR standees, sets up its menu in one visit and leaves it live. "
        "Admin and Artist accounts can use everything here too (roles include everything below them).")

f("My restaurants", "Profile → My restaurants", REP_PLUS,
  "Restaurants this rep may act on, each marked 'Menu live' or 'Not published yet', with 'Show the QR code'.",
  "Open as a rep with 2 activated restaurants.", "Both listed with the right status.")
f("Activate a standee", "My restaurants → Activate a standee", REP_PLUS,
  "Scan the standee QR or type its 8-character code → check → restaurant name + owner's phone (the owner signs in and pays with it) → confirm → 'This standee is live'. Can also activate as a new branch of an existing restaurant.",
  "Activate an unused test code with a test phone number.",
  "Restaurant created and linked to the code; owner can sign in with that phone. Used/foreign codes give clear errors.",
  notes="Standee assignment to reps is advisory - any rep can activate any free code (by design).")
f("Scan the standee (camera)", "Activate → Scan the code", REP_PLUS,
  "Reads the code from the standee's QR.", "Scan a printed standee.", "Code fills in. No camera → 'Type the code instead'.")
f("My standees", "Profile → My standees", REP_PLUS,
  "Standees an admin assigned to you, ready to activate, each with 'Save a printable standee'.",
  "Admin assigns 2 codes → rep opens My standees.", "Both listed; PDF saves.")
f("Restaurant menu (dishes)", "My restaurants → a restaurant", REP_PLUS,
  "Dishes list with drag reorder, status (Draft / Everything is live), Add a dish, Categories, Restaurant details, Import menu, Weekly reports, Preview, Publish.",
  "Open a restaurant and use each entry.", "All entries open; order saves.")
f("Add a dish (capture now / finished capture / image)", "Restaurant → Add a dish", REP_PLUS,
  "Three ways: 'Capture now' (6 photos; the 3D builds on its own and the dish becomes 3D later), from a finished capture, or image only.",
  "Add one dish each way.",
  "Image dish appears at once; 'Capture now' dish shows photo first and turns 3D when the model is ready (same public entry).",
  platform="APK · Web (web uses a simple 6-photo camera)")
f("Edit a dish with live preview", "Restaurant → tap a dish", REP_PLUS,
  "Name, price, description, section, veg/non-veg, available today, replace photo - with 'What a customer will see' preview.",
  "Edit a dish → Save dish.", "'Dish saved. Publish the menu…'.")
f("Rep publish (before payment)", "Restaurant → Publish the menu", REP_PLUS,
  "Same checklist and progress as the owner. An unpaid restaurant goes live with a 7-day pay-by window; the public page shows a payment-due banner, and switches OFF if not paid in time.",
  "Publish a new unpaid restaurant, scan its standee.",
  "Menu is live with the banner; owner gets 'Your menu is live — payment due'.")
f("Subscription card: trial, cash, notify owner", "Restaurant → Subscription card", REP_PLUS,
  "Start free trial (once per restaurant), Record cash payment (amount, method, reference → admin verifies), Notify owner to pay (SMS + in-app, with a cool-down).",
  "Try each action on a test restaurant.",
  "Trial starts; cash shows 'awaiting admin verification'; notify shows 'Sent… again in …'.")
f("Restaurant QR", "My restaurants → Show the QR code", REP_PLUS,
  "The same QR the owner sees, viewable and saveable.", "Open QR on a live restaurant.", "Same code as the owner's.")
f("Published standees (history)", "Profile → Published standees", REP_PLUS,
  "Restaurants this rep put live, by period. Admin sees every staff member's ('Put live by …').",
  "Pick a period.", "List with counts; admin sees all reps.")
f("Rep access ends", "Any rep restaurant screen", REP_PLUS,
  "If access is removed, screens say 'This restaurant is no longer assigned to you'.",
  "Remove a rep's access, then open the restaurant.", "Clear message, no crash.")

# ════════════════════════════════════════════════════════════════════════════
# 17. ARTIST
# ════════════════════════════════════════════════════════════════════════════
section("ART", "Model Artist / staff tools", "Home → Live projects tab",
        "For the in-house 3D team (Artist and Admin): see every user's finished uploads and produce or fix their models.")

f("Live projects list", "Home → Live projects", STAFF_ONLY,
  "Finished uploads from ALL users, with owner, 'Updated …', and actions.", "Open the tab.", "Projects from other users appear.")
f("Project owner details", "Live project → Created by", STAFF_ONLY,
  "Owner's name, phone, email, role and member since, with copy buttons.", "Tap the owner line.", "Details sheet opens.")
f("Upload photos project", "+ → Upload photos", STAFF_ONLY,
  "Create a project from 3–48 gallery photos instead of capturing.",
  "Pick 10 photos → Upload.", "Project created and uploads.")
f("Preview gallery", "Live project → Preview", STAFF_ONLY,
  "Browse every photo of a project, download single photos; delete a photo (Admin only).",
  "Open Preview, swipe, download one.", "Photos load; delete is not offered to Artist.")
f("Select photos → Create Model", "Preview → Select photos → Create Model", STAFF_ONLY,
  "Hand-pick 3–4 photos and start a model build.", "Select 4 → Create Model.", "Build starts and shows the selection trace.")
f("Export project files", "Live project → Export", STAFF_ONLY,
  "Download links for all of a project's files (time-limited).", "Tap Export.", "'Export ready — N files'; links expire.")
f("Staff model history & approve", "Live project → Models", STAFF_ONLY,
  "Every generation with its trace; 'Approve this model'; Optimize; Export.",
  "Approve a model.", "'Approved — no manual model needed'.")
f("Submit model (.glb)", "Live project → Submit model", STAFF_ONLY,
  "Upload a hand-made .glb to a project you do not own; the owner sees it in their Models.",
  "Choose a .glb → submit.", "'Model submitted'; owner sees it.")
f("Delete a user's project", "Live project → Delete project", ADMIN_ONLY,
  "Soft delete (team can restore) or permanent delete, typing the name.", "Delete a test project.", "Project removed from the list.")

# ════════════════════════════════════════════════════════════════════════════
# 18. ADMIN
# ════════════════════════════════════════════════════════════════════════════
section("ADM", "Admin area", "Profile → Standee inventory / Subscriptions",
        "Running the business: standee stock, plans and payments. Admin only.")

f("Standee inventory: mint a batch", "Profile → Standee inventory → Mint a batch", ADMIN_ONLY,
  "Create a run of permanent QR codes with a label, count and optional rep to assign them to.",
  "Mint 5 codes labelled 'Test run'.", "Batch listed with 5 codes.", notes="Codes are permanent - print and scan a couple first.")
f("Batch: assign, return, download", "Standee inventory → a batch", ADMIN_ONLY,
  "Assign the whole batch or one standee to a rep, reassign, return all to stock, download printable standee sheets (copies per page), download print-vendor CSV.",
  "Assign one code to a rep; download sheets.", "Rep sees it in My standees; PDF/CSV download.")
f("Standee → restaurant", "Batch → Show the restaurant this standee activated", ADMIN_ONLY,
  "For a used code: the restaurant's QR and who activated it.", "Open a used code.", "Shows the restaurant and the rep.")
f("Subscriptions: Plans tab", "Subscriptions → Plans", ADMIN_ONLY,
  "All restaurants with filters (Pending, All, Expiring 7d, In grace, Paused, Paused 90d+, Trial) and search by restaurant, owner, phone (last 4+) or email.",
  "Use each filter and a search.", "Lists and empty states are correct; chips fit on mobile.")
f("Subscriptions: Cash tab", "Subscriptions → Cash", ADMIN_ONLY,
  "Cash payments recorded by reps waiting for verification; approve or reject (reason needed).",
  "Rep records cash → admin approves.", "Plan activates; rep and owner notified.")
f("Payments journal", "Subscriptions → Payments", ADMIN_ONLY,
  "Every online payment attempt: Needs attention, All, Succeeded, Not completed. Find by order_… or pay_… id.",
  "Make a test payment, find it by id.", "Attempt found with its steps.")
f("Payment attempt detail & fixes", "Payments → an attempt", ADMIN_ONLY,
  "Step-by-step journal (started → Razorpay → recorded → applied → catalog), 'Check with Razorpay', 'Apply to catalog' when money arrived but the plan did not, Capture, Refund duplicate.",
  "Open a stuck attempt → Check with Razorpay → Apply.", "'Applied — the plan is active on the catalog.'")
f("Restaurant subscription panel", "Subscriptions → a restaurant", ADMIN_ONLY,
  "Start plan (manual payment), start trial, Comp until a date, Extend grace, standee allowance, Resync page / Resync 3D, ledger and online payments, refunds.",
  "On a test restaurant: Start plan, then Extend grace.", "Status updates and the owner is notified.",
  notes="Production to-do: remove the 'Comp until' option and make 'All' the default filter (learn.txt).")

# ════════════════════════════════════════════════════════════════════════════
# 19. PUBLIC MENU
# ════════════════════════════════════════════════════════════════════════════
section("MENU", "Public menu - what customers see (Mirage)", "Scan the QR / open the public link",
        "No app and no login. Everything here only changes after the owner (or rep) publishes.")

f("Scan QR → menu", "Phone camera", PUBLIC,
  "The printed QR opens the restaurant's menu page.", "Scan a live restaurant's QR.", "Menu opens fast on a phone browser.", platform="Any phone browser")
f("Not-live standee page", "Scan an unused / offline code", PUBLIC,
  "An unassigned standee or offline catalog shows a 'not live yet' page instead of an error.", "Scan a fresh minted code.", "Friendly 'not live' page.", platform="Any phone browser")
f("Theme, cover, layout, fonts", "Menu page", PUBLIC,
  "The restaurant's own look as published.", "Change theme in the app, publish, reload.", "New look, no flash of the old one.", platform="Any phone browser")
f("Open now, announcement, timed sections", "Menu page top", PUBLIC,
  "'Open · closes 11 pm' chip and weekly table, announcement strip, sections hidden/greyed outside their hours (India time).",
  "Check at different times of day.", "Matches the hours set in the app.", platform="Any phone browser")
f("Dish card & details", "Menu → a dish", PUBLIC,
  "Photo or 3D, price, veg mark, badges, diet & allergens, spice, serves, prep time, pairings.",
  "Open a fully filled dish.", "All filled fields show; empty ones are hidden.", platform="Any phone browser")
f("3D view & AR", "Dish → View in AR", PUBLIC,
  "Spin the dish in 3D and place it on the table (AR-capable phones), with restaurant branding.",
  "Android and iPhone.", "Android: AR placement. iPhone: currently the 3D viewer (room placement not yet served).", platform="Phone browser")
f("Search & diet filters", "Menu top", PUBLIC,
  "Search dishes; filter Veg only / Jain / Vegan / Gluten-free / No nuts.", "Search and filter.", "Correct dishes shown.", platform="Any phone browser")
f("Language switcher", "Menu top", PUBLIC,
  "Switch the menu into the extra languages; untranslated text shows in the main language.", "Switch to Hindi.", "Translated names/sections.", platform="Any phone browser")
f("Spotlight & offers", "Menu top", PUBLIC,
  "Spotlight carousel; offer strip, Offers pill and struck-through prices during offer windows.", "Open during a happy hour.", "Offer prices shown, minute-accurate.", platform="Any phone browser")
f("My plate", "Menu → + on dishes", PUBLIC,
  "Build a plate, see the total, 'Show to waiter' (big text) or send on WhatsApp; table number comes from the QR (?t=). Clears after 4 hours.",
  "Add 3 dishes → Show to waiter.", "Clean list with total.", platform="Any phone browser")
f("Customer buttons", "Menu", PUBLIC,
  "Rate us, Order on WhatsApp, Call waiter, Wi-Fi, Feedback form (one per visitor per day).", "Try each.", "Each works; feedback appears in the owner's Analytics.", platform="Any phone browser")
f("Google review prompt", "Menu, after some time", PUBLIC,
  "'Enjoyed your meal? Rate us on Google' - asked once a month after 15 minutes; never filters by star rating.", "Stay on the menu 15 min.", "Prompt appears once.", platform="Any phone browser")
f("Join for offers (sign-up)", "Menu → sign-up card", PUBLIC,
  "Name + number with an unticked consent box; opt-out later.", "Join with a test number.", "Appears in the owner's Customers list.", platform="Any phone browser")
f("Order online / Book a table", "Menu", PUBLIC,
  "Zomato / Swiggy chips and Book a table button.", "Tap each.", "Opens the right page.", platform="Any phone browser")
f("Payment-due banner / page switched off", "Menu", PUBLIC,
  "For a rep-published unpaid restaurant: a banner addressed to the owner; after the deadline the whole page is switched off.",
  "Use a test restaurant in pending payment.", "Banner shows (no prices / 'unpaid' wording); after deadline, page off.", platform="Any phone browser")
f("Menu web address", "yourname.<menu domain>", PUBLIC,
  "MasterChef restaurants' easy address opens the same menu.", "Open the address.", "Same menu as the QR.", platform="Any browser",)


# ── Extra reference tables ──────────────────────────────────────────────────
PLAN_TABLE = [
    ("Price per month", "Free 30 days", "₹1,199", "₹1,799", "₹2,499"),
    ("Yearly billing", "-", "30% off", "30% off", "30% off"),
    ("3D / AR dishes", "10", "10", "15", "30"),
    ("Image-only dishes", "Unlimited", "Unlimited", "Unlimited", "Unlimited"),
    ("Standee downloads (lifetime)", "-", "10", "15", "30"),
    ("Theme presets, cover, hours, announcement, diet filters", "✅", "✅", "✅", "✅"),
    ("Custom colours, layout & fonts", "✅", "❌", "✅", "✅"),
    ("Section timings", "✅", "❌", "✅", "✅"),
    ("Badges shown on menu", "12", "3", "12", "12"),
    ("Extra menu languages", "3", "0", "1", "3"),
    ("3D/AR branding, spotlight, 'Goes well with'", "✅", "❌", "✅", "✅"),
    ("Customer buttons", "All", "Rate us only", "All", "All"),
    ("Branded QR", "✅", "❌ (plain)", "✅", "✅"),
    ("Menu web address", "✅", "❌", "❌", "✅"),
    ("Offers & happy hour", "✅", "❌", "✅", "✅"),
    ("My plate", "✅", "❌", "✅", "✅"),
    ("Analytics, weekly report, AI tools, Today, Staff, Customers", "✅", "✅", "✅", "✅"),
]

SWITCHES = [
    ("appearanceEnabled", "Remote config (client config)", "Shows all customization screens (Themes, Badges, Languages, Spotlight, Menu web address…)"),
    ("subscriptionGatesEnabled", "Remote config", "Makes the server enforce plan limits at publish ('held back'). Off = everything allowed on the server. The app still asks for a plan at Publish."),
    ("SUBSCRIPTION_TESTING_PRICES", "API env", "Shows ₹3 / ₹5 / ₹7 test prices with a 'TEST PRICING' banner"),
    ("WEEKLY_REPORTS_ENABLED", "API env", "Turns the Monday weekly report on"),
    ("AI_API_KEY", "API env", "Shows the AI buttons (import menu, descriptions, write description)"),
    ("MENU_SUBDOMAIN_BASE + DNS", "API env + DNS", "Makes 'Menu web address' work"),
]


# ════════════════════════════════════════════════════════════════════════════
# Writers
# ════════════════════════════════════════════════════════════════════════════
def md_cell(s):
    return s.replace("|", "\\|").replace("\n", "<br>")


def access_label(code_char):
    return SYMBOL[code_char]


def write_md():
    out = []
    w = out.append
    total = len(FEATURES)
    w("# ReCapture — Feature Sheet")
    w("")
    w(f"**As of:** {AS_OF} · **Code checked:** ReCapture branch `{BRANCH}` · **Features listed:** {total}")
    w("")
    w("Every feature of ReCapture, grouped page by page, with who can use it, how to use it and what you "
      "should see. Use it to learn the app, to test it, and to send feedback.")
    w("")
    w("> **Testing?** Use [FEATURE-SHEET.csv](FEATURE-SHEET.csv) (open it in Excel or import it into Google Sheets). "
      "It has the same rows plus empty **Status / Tester / Date / Feedback / Severity** columns for you to fill in. "
      "Quote the feature **ID** (for example `PUB-03`) in any bug report.")
    w("")
    w("> **Editing this sheet:** don't edit this file or the CSV by hand. Change `build_feature_sheet.py` and run "
      "`python build_feature_sheet.py`. Both files are rebuilt.")
    w("")
    w("## How to read the sheet")
    w("")
    w("### User types (the access columns)")
    w("")
    w("| Code | User type | Who that is |")
    w("|---|---|---|")
    for code, name, desc in ROLES:
        w(f"| **{code}** | {name} | {desc} |")
    w("")
    w("| Symbol | Meaning |")
    w("|---|---|")
    w("| ✅ | Can use it fully |")
    w("| 🔒 | Partly. A plan limit, a lower cap, or the setting is saved but **held back** from the public menu. The row's notes say which |")
    w("| ❌ | Cannot use it / does not see it |")
    w("")
    w("**Things to know before testing:**")
    w("")
    w("1. **Roles include the ones below them.** Admin ⊇ Artist ⊇ Sales rep ⊇ User. An Admin can do everything an Artist, "
      "a Rep and a User can.")
    w("2. **Admin, Artist and Rep are also normal users.** They can have their own catalog. On their own catalog the **plan "
      "limits apply exactly as for any owner**. Their ✅ in plan-limited rows means the role allows it, not that the plan is skipped.")
    w("3. **Free trial, rep-published (pending payment) and complimentary restaurants get every customization** (MasterChef "
      "level), but only 10 3D dishes.")
    w("4. **Plan limits act at Publish, not at Save.** An owner can always design and save. Publishing sends only what the "
      "plan covers, and the publish screen lists the rest under *Held back on your plan*.")
    w("5. **Nothing reaches customers until Publish.** After any edit, check the public menu only after publishing.")
    w("6. **Switches.** Some features are hidden until a server switch is on (see [Switches](#switches-that-hide-or-show-features)). "
      "If a feature is missing, check its switch before reporting a bug.")
    w("")
    w("## Contents")
    w("")
    for i, s in enumerate(SECTIONS, 1):
        n = sum(1 for x in FEATURES if x["sec"] == s["code"])
        anchor = f"{i}-{s['title']}".lower()
        anchor = "".join(ch for ch in anchor if ch.isalnum() or ch in " -").replace(" ", "-")
        w(f"{i}. [{s['title']}](#{anchor}) · `{s['code']}` · {n} features")
    w(f"{len(SECTIONS) + 1}. [Plans at a glance](#plans-at-a-glance)")
    w(f"{len(SECTIONS) + 2}. [Switches that hide or show features](#switches-that-hide-or-show-features)")
    w(f"{len(SECTIONS) + 3}. [Known limits: don't report these as bugs](#known-limits-dont-report-these-as-bugs)")
    w(f"{len(SECTIONS) + 4}. [How to give feedback](#how-to-give-feedback)")
    w("")

    sr = 0
    sr_of = {}
    for x in FEATURES:
        sr += 1
        sr_of[x["id"]] = sr

    for i, s in enumerate(SECTIONS, 1):
        rows = [x for x in FEATURES if x["sec"] == s["code"]]
        w("---")
        w("")
        w(f"## {i}. {s['title']}")
        w("")
        w(f"**Where:** {s['where']}  ")
        w(s["intro"])
        w("")
        head = "| Sr. | ID | Feature | Where in the app | " + " | ".join(c for c, _, _ in ROLES) + " |"
        w(head)
        w("|" + "---|" * (4 + len(ROLES)))
        for x in rows:
            cells = [str(sr_of[x["id"]]), f"`{x['id']}`", f"**{md_cell(x['name'])}**", md_cell(x["where"])]
            cells += [access_label(ch) for ch in x["access"]]
            w("| " + " | ".join(cells) + " |")
        w("")
        w("<details open><summary><b>Details: what it is, how to use it, what to check</b></summary>")
        w("")
        for x in rows:
            w(f"#### {sr_of[x['id']]}. `{x['id']}` {x['name']}")
            w("")
            w(f"- **What it is:** {x['what']}")
            how = x["how"].split("\n")
            w("- **How to use / test:**")
            for step in how:
                w(f"  {step}" if step[:2].rstrip(".").isdigit() else f"  - {step}")
            w(f"- **Expected result:** {x['expect']}")
            if x["notes"]:
                w(f"- **Notes:** {x['notes']}")
            meta = f"- **Platform:** {x['platform']}"
            if x["switch"]:
                meta += f" · **Needs switch:** `{x['switch']}`"
            w(meta)
            w("")
        w("</details>")
        w("")

    w("---")
    w("")
    w("## Plans at a glance")
    w("")
    w("What each plan shows on the **public menu**. Everything can still be designed and saved on any plan.")
    w("")
    w("| | Trial / Pending payment / Comped | Taste (1st) | Signature (2nd) | MasterChef (3rd) |")
    w("|---|---|---|---|---|")
    for row in PLAN_TABLE:
        w("| " + " | ".join(row) + " |")
    w("")
    w("Other numbers: trial 30 days · grace after a plan ends 7 days · rep-published unpaid window 7 days · "
      "plan cards also list *WhatsApp & Instagram buttons* (Signature+) and *AR menu on your website*, "
      "*per-dish analytics*, *priority support* (MasterChef). These four are sales copy only; the app does not enforce them yet.")
    w("")
    w("## Switches that hide or show features")
    w("")
    w("| Switch | Where it is set | What it controls |")
    w("|---|---|---|")
    for row in SWITCHES:
        w(f"| `{row[0]}` | {row[1]} | {row[2]} |")
    w("")
    w("## Known limits: don't report these as bugs")
    w("")
    for item in [
        "**iPhone AR:** iPhone customers get the 3D viewer, not room placement, on the public menu.",
        "**Screenshot blocking on the QR screen** works on Android only (iOS and web cannot block screenshots).",
        "**Share link button** is hidden on web; Copy and Open work.",
        "**Staff access is not plan-gated**, and Managers cannot do full dish editing (Today screen only).",
        "**Rep standee assignment is advisory:** any rep can activate any free code. This is intentional.",
        "**Rep-published unpaid page goes fully dark** after 7 days, and its banner is visible to diners. Both were chosen on purpose.",
        "**3D spin videos** (customization stage 15) are deferred and not built.",
        "**Not built yet:** WhatsApp delivery of the weekly report, bulk WhatsApp sends, Hindi PDF menus, rep-side badge/diet editor, "
        "Mirage 'Our other branches' list, remembering the selected outlet after an app restart.",
        "**Printable PDF menu** was removed on purpose (replaced by Themes & Colours in the menu).",
    ]:
        w(f"- {item}")
    w("")
    w("## How to give feedback")
    w("")
    w("1. Open **FEATURE-SHEET.csv** in Excel, or import it into a shared Google Sheet (File → Import → Upload).")
    w("2. For each row you test, fill in **Status** (`Pass` / `Fail` / `Blocked` / `Not tested`), **Tested on** "
      "(APK / Web + phone model), **Tester**, **Date**, **Feedback / bug details** and **Severity** "
      "(`Critical` / `High` / `Medium` / `Low` / `Suggestion`).")
    w("3. For a failure, write the steps you took, what you expected (copy it from *Expected result*) and what you saw. "
      "Attach a screenshot and quote the **ID**.")
    w("4. Ideas and UI suggestions are welcome too. Use Severity `Suggestion`.")
    w("5. Test accounts per role (User / Rep / Artist / Admin) are shared by the dev team separately. Don't put phone numbers in the sheet.")
    w("")
    with open(os.path.join(HERE, "FEATURE-SHEET.md"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out))


def write_csv():
    titles = {s["code"]: f"{i}. {s['title']}" for i, s in enumerate(SECTIONS, 1)}
    header = (["Sr.", "ID", "Page / area", "Feature", "What it is", "How to use / test", "Expected result",
               "Where in the app"]
              + [f"{name} ({code})" for code, name, _ in ROLES]
              + ["Platform", "Needs switch", "Notes",
                 "Status (Pass/Fail/Blocked/Not tested)", "Tested on (APK/Web + device)", "Tester", "Date",
                 "Feedback / bug details", "Severity (Critical/High/Medium/Low/Suggestion)"])
    with open(os.path.join(HERE, "FEATURE-SHEET.csv"), "w", encoding="utf-8-sig", newline="") as fh:
        wr = csv.writer(fh)
        wr.writerow(header)
        for sr, x in enumerate(FEATURES, 1):
            wr.writerow([sr, x["id"], titles[x["sec"]], x["name"], x["what"], x["how"], x["expect"], x["where"]]
                        + [SYMBOL[ch] for ch in x["access"]]
                        + [x["platform"], x["switch"], x["notes"], "", "", "", "", "", ""])


if __name__ == "__main__":
    ids = [x["id"] for x in FEATURES]
    assert len(ids) == len(set(ids))
    write_md()
    write_csv()
    print(f"Wrote {len(FEATURES)} features in {len(SECTIONS)} sections.")
