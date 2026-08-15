# ─────────────────────────────────────────────────────────────────────────────
# ReCapture — Flutter Web image for Render (runtime: Docker).
#
# Two stages: the first compiles the web bundle with the full Flutter SDK, the
# second serves the ~39 MB of static output with nginx. The SDK (~1.5 GB) is
# left behind in the build stage and never ships.
#
# Render has no native Flutter build environment, which is the whole reason
# this service runs on Docker rather than a static-site build command.
#
# Local parity check before pushing (same inputs Render will use, because
# .dockerignore hides everything .gitignore hides):
#   docker build -t recapture-web .
#   docker run --rm -p 8080:80 recapture-web   → http://localhost:8080
# ─────────────────────────────────────────────────────────────────────────────

# Pinned to the SDK this app is developed against (`flutter --version` → 3.41.1,
# Dart 3.11.0). `stable` would float and can change the toolchain underneath a
# deploy with no commit of ours to blame, so bump this tag deliberately.
FROM ghcr.io/cirruslabs/flutter:3.41.1 AS build

# Which .env.<name> the app loads, and the backend it points at.
# Render exposes a service's environment variables to the build as build args,
# so setting API_BASE_URL under Settings → Environment overrides the default
# below without touching this file.
ARG APP_ENV=prod
# ARG API_BASE_URL=https://recapture-api.onrender.com
ARG API_BASE_URL=https://recapture-unvp.onrender.com

WORKDIR /app

# Dependencies before source: this layer stays cached until pubspec.* actually
# changes, so an ordinary code push skips `pub get` and its network round-trips.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# ── Recreate the .env assets ─────────────────────────────────────────────────
# pubspec.yaml lists .env, .env.dev, .env.staging and .env.prod under `assets:`,
# but .gitignore keeps all four out of the repo. Render builds from a clean git
# clone, so none of them exist here and `flutter build web` would abort with
#   Error detected in pubspec.yaml:
#   No file or variants found for asset: .env.
#   Target web_release_bundle failed: Exception: Failed to bundle asset files.
# Nothing in the app is broken — the files simply have to be regenerated at
# build time, which is also the only place the deployed API URL is decided.
#
# Truncate all four FIRST, then write the active one: main.dart loads
# .env.$APP_ENV and then overlays `.env` on top (see _loadEnv), so leaving the
# other three empty is precisely what lets API_BASE_URL above win.
RUN : > .env && : > .env.dev && : > .env.staging && : > .env.prod \
 && printf 'API_BASE_URL=%s\n' "$API_BASE_URL" > ".env.$APP_ENV"

# ENV is read by lib/utils/app_env.dart via String.fromEnvironment at COMPILE
# time — it is not an OS environment variable and cannot be set on Render's
# dashboard after the fact. It has to be baked in here.
RUN flutter build web --release --dart-define=ENV="$APP_ENV"


# ─────────────────────────────────────────────────────────────────────────────
# Serve
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:alpine

# nginx.conf is a TEMPLATE, not a finished config. The stock nginx entrypoint
# runs envsubst over /etc/nginx/templates/*.template at container start, which
# is how `listen ${PORT}` picks up the port Render injects. envsubst only
# replaces names that exist in the environment, so nginx's own $uri and
# $http_* survive untouched. Locally, PORT falls back to 80.
ENV PORT=80
COPY nginx.conf /etc/nginx/templates/default.conf.template

COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
