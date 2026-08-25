---
name: run-recapture
description: Run, build, launch, screenshot, and drive the ReCapture Flutter app. Use when asked to run the app, see/screenshot a screen, walk the login flow, or verify a UI change in the actually-running app (not just tests). Web-build driver — works headless.
---

# Run ReCapture (Flutter client)

ReCapture is the Flutter photogrammetry capture app at the repo root. On this
machine (Windows, no Android emulator attached) the reliable programmatic path
is the **Flutter web release build** driven by
`.claude/skills/run-recapture/driver.mjs` — a stdin-command REPL over
playwright-core using the **system Chrome, headless** (no browser download).
All paths below are relative to the repo root.

Native capture surfaces (camera preview, sensors, permissions channels) do not
exist on web — the drivable scope is splash → login → **Projects/Home**,
create-project, and any screen that doesn't touch a MethodChannel. That covers
most UI-layer PRs.

## Prerequisites

- Flutter SDK on PATH (`flutter devices` lists windows/chrome/edge here).
- Node ≥ 22 and system Chrome (`C:\Program Files\Google\Chrome\Application\chrome.exe`).
- One-time driver deps (installs `playwright-core` only):

```bash
cd .claude/skills/run-recapture && npm i
```

## Build

```bash
flutter build web
```

~90s. Produces `build/web/`. Rebuild after any `lib/` change you want to see.
(A missing `.env.dev` only prints a boot WARNING — not a blocker.)

## Run + drive (agent path — use this)

The driver serves `build/web` itself on port 8642 (`--serve`), launches
headless Chrome, and reads commands from stdin. Screenshots land in
`.claude/skills/run-recapture/shots/<name>.png`.

The full verified login → Home flow (dev master OTP is `555555` — accepted by
the stubbed `AuthRepository` until the real API is wired):

```bash
cd .claude/skills/run-recapture && printf 'goto
click Phone number
type 9876543210
click Send OTP
clickxy 40 199
wait 1500
insert 555555
wait 3000
ss home
tree
quit
' | node driver.mjs --serve
```

`clickxy 40 199` = the first OTP box at the driver's 412×915 viewport.

Driver commands:

| command | what it does |
|---|---|
| `goto [url]` | load the app, wait for the engine, enable the semantics DOM |
| `ss <name>` | screenshot → `shots/<name>.png` |
| `tree` | list all visible semantics labels |
| `find <text>` / `click <text>` | find / click widget by (partial) semantics label |
| `clickxy <x> <y>` | raw coordinate click (canvas-only targets) |
| `type <text>` / `insert <text>` | keystrokes / paste-style single input event |
| `press <key>` / `wait <ms>` / `eval <js>` | key press / sleep / page JS |
| `quit` | close Chrome and exit (also stops the static server) |

Everything in one driver invocation is one browser session; auth persists
across `goto` within it (tokens in browser storage), not across invocations —
each fresh run walks login again, which keeps runs deterministic.

## Run (human path)

```bash
flutter run -d web-server --web-port 8642 --web-hostname 127.0.0.1
```

then open the printed URL in a browser. Debug build, hot reload via `r`.
**One browser tab only** — see Gotchas. On a phone/emulator: standard
`flutter run` (not exercised here).

## Test / analyze

```bash
flutter analyze
flutter test test/projects test/offline   # or the full suite: flutter test
```

## Gotchas (all hit for real)

- **Flutter web renders to canvas — the DOM is empty.** Nothing is clickable
  by selector until the semantics tree is enabled. The driver does this in
  `goto` by dispatching a DOM `click` on `flt-semantics-placeholder`; a
  playwright pointer click on it MISSES (the element is offscreen).
- **`flutter run -d web-server` (debug) pairs with exactly ONE browser
  client.** The first Chrome loads fine; every later fresh browser hangs
  >3 min waiting for the bundle. That's why the agent path is the release
  build + `--serve`. Use the debug server only for one live hot-reload
  session.
- **Killing `flutter run` on Windows orphans a `dartvm` listener** on the
  port → the driver's `--serve` fails with `EADDRINUSE`. Fix:
  `powershell "Get-NetTCPConnection -LocalPort 8642 -State Listen | %{ Stop-Process -Id $_.OwningProcess -Force }"`.
- **Semantic labels concatenate up the ancestor chain** (a container's label
  is all its children joined), so several nodes match any text. The driver's
  `click` picks the *shortest* matching label — the most specific widget.
- **The OTP boxes silently drop fast keystrokes** (consistently 4 of 6 digits
  landed, even with 350ms/keystroke). Use `insert 555555` — one paste-style
  input event; the screen's `_onChanged` treats it as SMS-autofill/paste and
  auto-verifies.
- Release build tree-shakes icons and prints a `CupertinoIcons` font warning —
  harmless, build still succeeds.

## Troubleshooting

| symptom | fix |
|---|---|
| `EADDRINUSE: 127.0.0.1:8642` from the driver | stray `dartvm` — kill via the PowerShell one-liner in Gotchas |
| `goto` times out on `flt-glass-pane` | you're pointing at a debug `web-server` that already served its one client — use `--serve` against the release build |
| `tree` prints `(empty — did goto run?)` | run `goto` first; if it persists the placeholder click failed — rerun `goto` |
| `click X` → NOT FOUND | run `tree`; the label may differ or the widget has no semantics — fall back to `clickxy` using a fresh `ss` |
| No release build | `flutter build web` from the repo root |
