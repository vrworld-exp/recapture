# Makefile — ReCapture dev workflow shortcuts
# Usage:
#   make run.dev | make run.staging | make run.prod
#   make build.apk.dev | make build.apk.staging | make build.apk.prod
#   make build.ipa.dev | make build.ipa.staging | make build.ipa.prod
#   make run.web
#   make build.web.dev | make build.web.staging | make build.web.prod
#   make verify
#   make clean

.PHONY: run.dev run.staging run.prod run.web \
        build.apk.dev build.apk.staging build.apk.prod \
        build.ipa.dev build.ipa.staging build.ipa.prod \
        build.web.dev build.web.staging build.web.prod \
        verify clean \
        deploy.android.build deploy.android.internal deploy.ios.testflight lanes

# ── Run (hot-reload dev sessions) ─────────────────────────────────────────────

run.dev:
	flutter run --dart-define=ENV=dev

run.staging:
	flutter run --dart-define=ENV=staging

run.prod:
	flutter run --dart-define=ENV=prod

# ── Android APK ───────────────────────────────────────────────────────────────

build.apk.dev:
	flutter build apk --debug --dart-define=ENV=dev

build.apk.staging:
	flutter build apk --dart-define=ENV=staging

build.apk.prod:
	flutter build apk --release --dart-define=ENV=prod

# ── iOS IPA ───────────────────────────────────────────────────────────────────

build.ipa.dev:
	flutter build ipa --dart-define=ENV=dev

build.ipa.staging:
	flutter build ipa --dart-define=ENV=staging

build.ipa.prod:
	flutter build ipa --release --dart-define=ENV=prod

# ── Flutter web ───────────────────────────────────────────────────────────────
#
# Web is a FIRST-CLASS TARGET for authoring, not a preview: the phase ships the
# APK and the web build together, so each is one command here and both are run
# before a batch is called done. See docs/next-phase/web-capability-matrix.md
# for what the web build deliberately does NOT do (no share sheet, no camera
# source, no AR on desktop).
#
# DEPLOY NOTE — deep links need a hosting rewrite. `/catalog/products/:id` is a
# client-side route; a page REFRESH on it is a real GET the host must rewrite to
# index.html or the user gets a 404 on their own product. There is no hosting
# config in this repo — whichever host is chosen needs that rule. If the app is
# served from a sub-path rather than the domain root, add `--base-href=/path/`
# to the build.

run.web:
	flutter run -d chrome --dart-define=ENV=dev

build.web.dev:
	flutter build web --dart-define=ENV=dev

build.web.staging:
	flutter build web --release --dart-define=ENV=staging

build.web.prod:
	flutter build web --release --dart-define=ENV=prod

# ── Verification ──────────────────────────────────────────────────────────────
#
# The gate a batch must pass. Both targets are built on purpose: a green
# `flutter test` does not prove the web build ships, and the two toolchains fail
# in different ways.

verify:
	flutter analyze
	flutter test
	flutter build web --release
	flutter build apk --release

# ── Utilities ─────────────────────────────────────────────────────────────────

clean:
	flutter clean

# ── Fastlane deploy targets ───────────────────────────────────────────────────

## Build release AAB only (no upload) — requires android/key.properties
deploy.android.build:
	bundle exec fastlane android build_release

## Build + upload to Play Internal Testing track
## Requires: fastlane/secrets/play-store-service-account.json
deploy.android.internal:
	bundle exec fastlane android internal

## Build + upload to TestFlight (STUB — will fail until activated)
## See activation checklist in fastlane/Fastfile under 'iOS PLATFORM — STUB'
deploy.ios.testflight:
	bundle exec fastlane ios testflight

## List all available Fastlane lanes
lanes:
	bundle exec fastlane lanes
