# Makefile — ReCapture dev workflow shortcuts
# Usage:
#   make run.dev | make run.staging | make run.prod
#   make build.apk.dev | make build.apk.staging | make build.apk.prod
#   make build.ipa.dev | make build.ipa.staging | make build.ipa.prod
#   make clean

.PHONY: run.dev run.staging run.prod \
        build.apk.dev build.apk.staging build.apk.prod \
        build.ipa.dev build.ipa.staging build.ipa.prod \
        clean

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

# ── Utilities ─────────────────────────────────────────────────────────────────

clean:
	flutter clean
