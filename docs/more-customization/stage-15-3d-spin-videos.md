# Stage 15 — Instagram-ready 3D spin videos

**Side:** recapture-api (render worker) + Flutter. No Mirage change.
**Depends on:** dishes with a published 3D model (GLB). Stage 2/3 theme + logo used for the frame.
**Size:** L
**Priority:** ⭐ #2 — the feature owners *show off*, and every post advertises Mirage.

## Why

We already have something no other menu provider has: a real 3D model of each dish. Owners
struggle to make content for Instagram. One tap → a 6–10 s 360° turntable clip of the dish with the
restaurant's logo and "Scan our menu to see it in AR" → post as a Reel or Story. Free marketing for
them, free distribution for us.

## What the owner gets

- Product screen (3D dishes only): **🎬 Make video** → pick format + style → ~1 minute later the video
  is ready → **Share** (Instagram / WhatsApp status / save to gallery).
- Formats: **Reel/Story 9:16 (1080×1920)**, **Square 1:1 (1080×1080)**, **Landscape 16:9**.
- Styles: `spin` (one 360° turn), `reveal` (zoom in from far, then spin), `duo` (two dishes side by
  side). Background: theme colour gradient, Stage 7.1 stage texture (marble/wood), or blurred cover photo.
- Overlay: logo top-left, dish name + price (toggle), bottom strip "Scan the QR · See it in 3D" or
  a custom caption (≤ 40 chars), small "Made with Mirage" watermark (removable on Premium, Stage 8).
- **Menu montage**: pick 3–6 dishes → one 15 s video cycling through them.
- Suggested caption text (Stage 13 AI, optional) with hashtags, one tap copy.

---

## Rendering (recapture-api worker)

- New job type `DISH_VIDEO_RENDER`, processor `dishVideoProcessor.ts`, registered in
  `processorRegistry.ts`; runs in the **worker**, never the API process.
- Headless rendering: Puppeteer/Playwright + a tiny local render page using **three.js**
  (GLTFLoader + DRACO/meshopt if the optimizer uses them — check `modelOptimizerService.ts`)
  with a fixed camera path; capture frames deterministically (step the animation per frame, don't
  rely on real time), 30 fps, then **ffmpeg** → H.264 MP4 (yuv420p, `+faststart`, ~6–8 Mbps) which
  Instagram accepts.
- Overlays drawn in the render page (HTML/CSS over the canvas) so fonts/colours match the theme.
- Output → S3 `videos/<catalogId>/<productId>/<hash>.mp4` + a poster JPG, served via CloudFront.
  `hash` = model version + options, so identical requests are served from cache instantly.
- Container: the worker image needs Chromium + ffmpeg + GPU-less WebGL (SwiftShader). Add to the
  `Dockerfile` for the worker only; document RAM needs (~1 GB per concurrent render). Concurrency 1–2.
- Limits: 20 renders/catalog/day, timeout 3 min, model > 25 MB rejected with a clear message.

## Data

`DishVideo { catalogId, productIds[], format, style, options, status: QUEUED|PROCESSING|READY|FAILED, videoKey?, posterKey?, error?, createdAt }`.
Delete videos when the product/model is deleted (same cleanup pattern as
`docs/camera/storage-cleanup-on-delete.md`).

## Flutter

- **Make video** sheet: format chips, style chips, background, caption, toggles; live static
  preview (poster frame) if possible.
- Progress card (poll like model generation); notification when ready if the user left the screen.
- Player + share via the platform share sheet (`share_plus`) with the MP4 file; on web, a download.
- "My videos" gallery on the catalog screen.
- Rep: can generate for delegated catalogs — great to hand over at the onboarding visit
  ("here's your first Reel").

## Analytics / growth

- Put `?src=reel` on the QR/URL in the video's end card so Stage 9 can report
  "57 visits came from your videos".
- Track `video_created`, `video_shared` (client-side) in ReCapture.

## Tests

- Processor: options hash → cache hit skips render; timeout → FAILED with reason; S3 keys correct.
- Render page: deterministic frame count for a fixture GLB (snapshot the first/middle/last frame).
- ffmpeg output probe: codec h264, yuv420p, correct resolution and duration.

## Done when

- [ ] A 3D dish produces a 9:16 MP4 in < 90 s that uploads to Instagram Reels without re-encode warnings.
- [ ] Logo, dish name and theme colours are correct; the same request twice returns instantly.
- [ ] A montage of 4 dishes works on Android share sheet and web download.
