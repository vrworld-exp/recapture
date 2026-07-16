# ReCapture — Building the iOS App on a Mac

Step-by-step guide to build, test, and ship the ReCapture iOS app.

- **Bundle id:** `com.mayasabhaxr.recapture`
- **Scheme:** `Runner` (single scheme, no build flavors)
- **Entry point:** `lib/main.dart`
- **iOS deployment target:** 14.0
- **Note:** the Swift native code (camera/sensors/upload) is **unverified on
  device** — expect to debug it in Step 3.

---

## Prerequisites (one-time)

1. A Mac (Apple Silicon or Intel) on a recent macOS.
2. **Apple Developer Program** membership — $99/yr — https://developer.apple.com
3. A real **iPhone** and **iPad** for testing.

---

## Step 1 — Install the toolchain

```bash
# 1. Install Xcode from the Mac App Store, then accept the license:
sudo xcodebuild -license accept
xcode-select --install

# 2. Install CocoaPods (iOS dependency manager):
sudo gem install cocoapods

# 3. Install Flutter, then verify the iOS toolchain is green:
flutter doctor
```

> Fix everything `flutter doctor` flags for **Xcode** and **iOS** before moving on.

---

## Step 2 — Get the code and dependencies

```bash
git clone <your-repo-url>
cd ReCapture

flutter pub get
dart run build_runner build --delete-conflicting-outputs   # codegen
cd ios && pod install && cd ..                              # iOS native deps
```

> Make sure `.env` / `.env.dev` files are present (they load at runtime).

---

## Step 3 — Run on a real device (verify native code FIRST)

```bash
open ios/Runner.xcworkspace     # IMPORTANT: .xcworkspace, NOT .xcodeproj
```

In Xcode:

1. Select the **Runner** target → **Signing & Capabilities**.
2. Check **Automatically manage signing** and choose your **Team**.
3. Plug in your **iPhone**, select it as the target, press **▶︎ Run**.
4. Repeat on an **iPad**.

Or from the terminal:

```bash
flutter devices                 # confirm iPhone/iPad shows up
flutter run --release
```

> Test the full flow: camera preview, capture, tilt/sensor overlays,
> blur/exposure gating, background upload. **Fix native issues here.**

---

## Step 4 — Register the app in App Store Connect

1. Go to https://appstoreconnect.apple.com → **My Apps → +**
2. Create a new app with bundle id `com.mayasabhaxr.recapture`.
3. Fill in name, category, and **privacy details** (declare Camera + Photos).

---

## Step 5 — Build the release archive

```bash
flutter build ipa --release
```

Output: `build/ios/ipa/*.ipa`

> If command-line signing isn't set up, archive from Xcode instead:
> **Product → Archive → Distribute App**.

---

## Step 6 — Upload to TestFlight (beta first)

**Option A — Xcode (easiest):**
Window → **Organizer** → select archive → **Distribute App →
App Store Connect → Upload**.

**Option B — Terminal:**

```bash
xcrun altool --upload-app -f build/ios/ipa/recapture.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Then in App Store Connect → **TestFlight**, add your beta testers.

---

## Step 7 — Submit to the App Store

1. Add **screenshots** (required iPhone + iPad sizes).
2. Add description, keywords, support URL, privacy policy URL.
3. Attach the build → **Submit for Review**.

> Apple review takes ~1–3 days. Common rejections for camera apps: missing
> permission-usage justification and incomplete privacy labels.

---

## Optional — Automate with Fastlane (after a manual release works)

A `fastlane/` folder already exists (Android-oriented; iOS `Fastfile` is empty).
Add an iOS lane using **`match`** (signing) + **`pilot`** (TestFlight) so future
releases are one command. Do this only **after** a manual release succeeds.

---

## Quick reference — the realistic order

1. `flutter doctor` clean → `pod install` → **run on real iPhone + iPad**
2. Fix the native Swift issues you find *(this is where the time goes)*
3. `flutter build ipa` → TestFlight → beta users
4. Screenshots + privacy labels → submit for review
