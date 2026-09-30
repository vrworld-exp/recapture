# More-customization — rollout record

Stage 8.3 asks for one line per stage: date shipped, commit, and anything that differed from the
prompt. Everything below is **built, uncommitted and untested** as of 2026-09-30 — fill the
"Shipped" and "Commit" columns as each one actually goes out.

## Order (stage-08 §8.3)

1. **Stage 1 to Mirage first, alone.** Deploy mirage-be + mirage-fe; confirm zero visual change on
   3 live restaurants.
2. **Every later stage: Mirage deploy BEFORE the ReCapture release that sends its fields.** An
   older Mirage ignores fields it does not know, but a newer ReCapture talking to an old Mirage
   means the owner's edits silently do not show.
3. **The switch.** The app hides every customization entry point (Appearance, Badges, Languages,
   Spotlight & buttons, Menu web address, QR style, the product-editor tiles) until ops set
   `appearanceEnabled: true` on the `client_configs` document. Absent = hidden. Turn it on for the
   internal test catalogs (see `learn.txt`), then two friendly clients, then everyone.
4. **Plan gating** stays off with `subscriptionGatesEnabled` (the Stage 5 subscription flag): while
   it is off, every plan gets every customization. Gating turns on with that flag, not separately.
5. **Menu subdomains** need, before anyone saves an address: wildcard DNS `*.<menu domain>` →
   the Mirage-fe host, a wildcard TLS certificate (Vercel supports wildcard domains), Mirage-fe
   `VITE_MENU_DOMAIN=<menu domain>`, recapture-api `MENU_SUBDOMAIN_BASE=<menu domain>`. Without
   the API variable the address is saved but no URL is shown.
6. **Marketing site** (mayasabhaxr-fe): "Make it yours" section with before/after screenshots of
   2–3 presets — once Stage 3 is live.

## Per stage

| Stage | Shipped | Commit | Differed from the prompt |
|---|---|---|---|
| 1 Theme foundations | | | See stage-01 status. |
| 2 Appearance screen | | | Contrast rule mirrors `applyTheme.ts` (Basalt red 3.96:1). |
| 3 Cover / layout / fonts | | | See stage-03 status. |
| 4 Hours / announcement / windows | | | Hours on their own screen; time-zone not editable yet. |
| 5 Badges / dietary | | | Rep editor has no badge section; ≤ 6 badges per dish. |
| 6 Multi-language | | | Owner types everything (Q3); chrome en + hi only; progress computed in the app. |
| 7 AR / pairings / buttons / QR | | | Dishes published by NAME, not Mirage id; `jsqr` now a runtime dependency; no tests (user). |
| 8 Plan gating / subdomain / rollout | | | Rollout flag served on `GET /catalog/entitlements`, not the strict remote-config payload; no tests (user). |
