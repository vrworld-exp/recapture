# ReCapture — Developer Build Commands
# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites: make (built-in on macOS/Linux), Flutter 3.22.x on PATH
# Windows: run the flutter commands directly (see comments beside each target)
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: run.dev run.staging run.prod \
        build.apk.dev build.apk.staging build.apk.prod \
        build.ios.dev build.ios.staging \
        clean analyze env.check

# ── Run targets ───────────────────────────────────────────────────────────────

## Start app in development mode (points to localhost or dev API)
run.dev:
	flutter run --dart-define=ENV=dev

## Start app in staging mode (points to staging Render API)
run.staging:
	flutter run --dart-define=ENV=staging

## Start app in production mode (points to production API — use with caution)
run.prod:
	flutter run --dart-define=ENV=prod

## Run on a specific device (pass DEVICE=<device-id>)
## Usage: make run.dev.device DEVICE=emulator-5554
run.dev.device:
	flutter run --dart-define=ENV=dev -d $(DEVICE)

# ── APK build targets ─────────────────────────────────────────────────────────

## Build debug APK for development
build.apk.dev:
	flutter build apk --debug --dart-define=ENV=dev
	@echo "✅ Dev APK: build/app/outputs/flutter-apk/app-debug.apk"

## Build release APK for staging (requires signing setup)
build.apk.staging:
	flutter build apk --release --dart-define=ENV=staging
	@echo "✅ Staging APK: build/app/outputs/flutter-apk/app-release.apk"

## Build release APK for production (requires signing setup)
build.apk.prod:
	flutter build apk --release --dart-define=ENV=prod
	@echo "✅ Prod APK: build/app/outputs/flutter-apk/app-release.apk"

# ── iOS build targets ─────────────────────────────────────────────────────────

## Build iOS (no codesign) for development — macOS only
build.ios.dev:
	flutter build ios --no-codesign --dart-define=ENV=dev
	@echo "✅ Dev iOS build complete"

## Build iOS (no codesign) for staging — macOS only
build.ios.staging:
	flutter build ios --no-codesign --dart-define=ENV=staging
	@echo "✅ Staging iOS build complete"

# ── Utility targets ───────────────────────────────────────────────────────────

## Run flutter analyze
analyze:
	flutter analyze

## Clean build artifacts
clean:
	flutter clean
	@echo "✅ Build artifacts cleaned"

## Show which env file would be loaded per environment
env.check:
	@echo "dev     → .env.dev     (API: $$(grep API_BASE_URL .env.dev | cut -d= -f2))"
	@echo "staging → .env.staging (API: $$(grep API_BASE_URL .env.staging | cut -d= -f2))"
	@echo "prod    → .env.prod    (API: $$(grep API_BASE_URL .env.prod | cut -d= -f2))"
