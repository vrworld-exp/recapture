# Implementation Prompt — Remove Prepare-Images: selection goes straight to Maya AI

Client-only (Flutter). **No backend change, no deploy, no migration.** Every
endpoint this flow needs already exists and already works; this removes a client
step, nothing else.

---

## The decision (read first)

Staff select 3–4 photos in the Preview gallery and press **Create Model**. Today
that opens **Prepare-Images** (`ImagePrepScreen`) — polygon/rectangle crop,
lighting, rotate, Save — which bakes edited copies, uploads them to the job's
`model-input/` namespace, and only then calls Create-Model.

That editing step is being **removed**. After this change, Create Model sends the
selected photos' ORIGINAL keys straight to the existing Create-Model endpoint and
opens the generation screen.

**Why:** the unedited path is the one confirmed working end-to-end
(selection → `POST /admin/projects/:id/model` → job → `meshyModelProcessor` →
Meshy → artifacts re-hosted to `msxr-model-artifacts` → CloudFront URLs on the
record → viewer + history). The editing path adds three failure points that only
exist when a photo is edited — a slow `package:image` bake (which on the web
build runs on the UI thread, because `compute()` has no isolate there), a
presigned PUT that needs bucket CORS, and one extra API route that must be
present on the deployed backend. The feature is not worth those failure modes
right now.

### What this is NOT

- **Not a backend change.** `POST /admin/projects/:id/model-images/upload-urls`
  and `GET /admin/projects/:id/photo-bytes` stay exactly as they are, as does
  the reserved `model-input/` namespace and its handling in the export manifest,
  the capture processor and the hard-delete purge. They become unused by the
  client, which costs nothing. **Do not delete backend code in this change** —
  an older installed app build still calls those routes, and touching the
  backend turns a zero-risk client edit into a deploy.
- **Not a change to Create-Model itself.** `createModel(projectId, keys,
  idempotencyKey:)` in `live_projects_repository.dart`, the create route, the
  worker, the artifacts, the polling and the viewer are all untouched.
- **Not a change to the server-side "Generate 3D model" button**
  (`autoGenerateModel` / `POST /model/auto`). Different flow, different screen,
  leave it alone.
- **Not a change to the 3–4 photo selection rule** (`kMinModelPhotos` /
  `kMaxModelPhotos`), the selection UI, the CTA copy, or the download/delete
  paths in the gallery.
- **Not a change to Model history or `ModelViewerScreen`.**

### Flow after the change

Projects → **Preview** → select photos (3–4) → **Create Model** → *(no
intermediate screen)* → `ModelGenerationScreen` polls QUEUED → PROCESSING →
SUCCEEDED → **View 3D Model**. The record also appears in **Models (N)** for
that project, exactly as it does today.

---

## 1. Files to DELETE

Client source:

| Path | Why it goes |
|---|---|
| `lib/presentation/screens/projects/image_prep_screen.dart` | The screen itself |
| `lib/presentation/screens/projects/image_prep_crop_editor.dart` | Its crop layer + `AppliedCropOverlayPainter` |
| `lib/application/projects/image_prep_exporter.dart` | The JPEG bake (`ImagePrepExporter`, `ExportedImage`, `exportEditedImage`) |
| `lib/application/projects/image_prep_image_loader.dart` | Fetches original bytes for editing (`PrepImageLoader`, `prepImageLoaderProvider`) |
| `lib/domain/entities/image_edit.dart` | `ImageEditState`, `EditPoint`, `RectCrop`, `LightingAdjust`, crop math |

Tests (they test only the deleted code):

- `test/projects/image_prep_screen_test.dart`
- `test/projects/image_prep_crop_editor_test.dart`
- `test/projects/image_prep_exporter_test.dart`
- `test/projects/image_prep_image_loader_test.dart`
- `test/projects/image_edit_test.dart`

Verify nothing else imports any of them before deleting:

```bash
grep -rn "image_prep_\|image_edit.dart" lib test
```

The only expected hit outside the deleted set is
`lib/presentation/screens/projects/preview_gallery_screen.dart` (§2.1) and
`test/projects/model_generation_test.dart` (§4.2).

---

## 2. Files to EDIT

### 2.1 `lib/presentation/screens/projects/preview_gallery_screen.dart`

This is the whole feature. Remove `import 'image_prep_screen.dart';` and replace
`_createModel()` (currently at line 104) with a direct request.

**Preserve these four invariants — each one is load-bearing:**

1. **The idempotency key formula must not change.** Copy it verbatim from
   `image_prep_screen.dart` into this state class. It is what makes a
   double-tap resolve to the FIRST record server-side instead of paying for a
   second Meshy generation, and `model_generation_test.dart` pins that the same
   selection always yields the same key.
2. **An in-flight guard.** The prep screen owned "one request at a time"; the
   gallery must own it now, or a fast double-tap fires two requests before the
   first response lands.
3. **Mapped copy only on failure** — `failureCopy(e)`, already defined at the
   top of this file. Never a raw error, code or URL.
4. **Selection is cleared only on SUCCESS.** On failure the picked photos must
   survive so the user can retry without re-picking.

```dart
  /// A stable key for one (project, keys) request: a double-tap resolves to the
  /// SAME record server-side instead of a second PAID generation.
  String _idempotencyKeyFor(List<String> keys) {
    final sorted = [...keys]..sort();
    return '${widget.projectId}:${sorted.join('|')}'.hashCode.toRadixString(16);
  }

  /// Sends the selected photos to Maya AI and opens the generation screen.
  Future<void> _createModel() async {
    if (!_canCreate || _creating) return;
    final keys = [
      for (final photo in ref
              .read(previewGalleryProvider(widget.projectId))
              .valueOrNull
              ?.files ??
          const <PreviewPhoto>[])
        if (_selected.contains(photo.key)) photo.key,
    ];
    if (keys.length < kMinModelPhotos) return;

    setState(() => _creating = true);
    try {
      final model = await ref
          .read(modelGenerationProvider(widget.projectId).notifier)
          .createModel(keys, idempotencyKey: _idempotencyKeyFor(keys));
      if (!mounted) return;
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelGenerationScreen(
            projectId: widget.projectId,
            modelId: model.id,
          ),
        ),
      );
    } catch (e) {
      // A dialog, not a snackbar: this press spends credits and a toast that
      // fades in four seconds is how a real failure gets reported as "nothing
      // happened".
      if (mounted) await _showCreateFailure(failureCopy(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }
```

Also in this file:

- add `bool _creating = false;` beside `_selecting` / `_selected`;
- add `_showCreateFailure(String message)` — an `AlertDialog` with
  `key: const ValueKey('create_model_error')`, title *"Couldn't start the
  model"*, body = the mapped copy, one **OK** action;
- in `_createModelBar`, feed the CTA `isLoading: _creating` and
  `onPressed: (_canCreate && !_creating) ? _createModel : null` so the press
  has visible feedback while the request is in flight;
- keep `kMinModelPhotos`, `kMaxModelPhotos`, `_canCreate`, `_toggleSelecting`,
  `_toggle`, the hint copy and every download/delete/viewer path untouched.

Imports: `image_prep_screen.dart` goes; `model_generation_notifier.dart` and
`model_generation_screen.dart` must be present (the screen import already is —
check whether the notifier one needs adding).

### 2.2 `lib/data/repositories/live_projects_repository.dart`

Delete the three members that existed only for Prepare-Images — from BOTH the
abstract interface and the `LiveProjectsRepositoryImpl`:

- `requestModelImageUploads(String projectId, int count)`
- `uploadModelImage(ModelImageUploadSlot slot, Uint8List bytes)`
- `fetchPhotoBytes(String projectId, String key)`

…and the now-unreferenced `class ModelImageUploadSlot`.

**Keep** `createModel`, `autoGenerateModel`, `listModels`, `approveModel`,
`export`, `deletePhotos`, `deleteProject` and `_translate` exactly as they are.
After the deletions, check whether `import 'dart:typed_data';` is still needed in
this file (`Uint8List` may have no other use) and drop it if not.

### 2.3 `pubspec.yaml`

`image: ^4.2.0` (line 55) exists only for the exporter's decode/encode. Once
§4.2 is done and `grep -rn "package:image/image.dart" lib test` returns nothing,
remove the dependency and run `flutter pub get`. If any test still builds
synthetic PNGs with it, either clean that test up too or move `image:` to
`dev_dependencies` — **do not leave it in `dependencies` while unused in `lib/`.**

### 2.4 `AGENTS.md`

Replace the **"Prepare-Images (edited model inputs)"** bullet (≈ lines 179–190)
with a shorter one that keeps the SERVER contract documented and records that the
client no longer uses it — the namespace behaviour still governs the backend:

> - **`model-input/` namespace (reserved, currently unused by the client).**
>   `POST /admin/projects/:id/model-images/upload-urls` presigns PUTs into the
>   exportable job's reserved `model-input/` namespace under `rawPrefix`, and
>   `GET /admin/projects/:id/photo-bytes` reads one capture photo through the
>   API. Both exist for staff-edited model inputs; the client's editing screen
>   was removed on <DATE> (selection now goes straight to Create-Model), so
>   nothing calls them today. The namespace rules stay: sibling of `deleted/`,
>   excluded from the export manifest and from the capture processor's
>   object-count re-verification, covered by the admin hard-delete purge.

---

## 3. What must still work afterwards (acceptance criteria)

1. Preview → select 3 photos → **Create Model** → the generation screen opens
   with **no intermediate screen**, and the request carried exactly the selected
   keys, in manifest order.
2. Selecting 4 works; 2 leaves the CTA disabled with the existing hint; a 5th
   tap cannot exceed 4.
3. Pressing Create Model twice quickly produces **one** record (in-flight guard
   client-side, identical idempotency key server-side).
4. A failed create shows mapped copy in a dialog and **keeps the selection**.
5. The generation screen progresses QUEUED → PROCESSING (with percent) →
   SUCCEEDED → **View 3D Model** renders the GLB.
6. The finished model appears under **Models (N)** for that project and survives
   an app restart (it is server-side state).
7. The non-staff owner surface is unchanged.
8. `flutter analyze lib test` reports no NEW issues; `flutter test` is green.
9. `grep -rn "image_prep\|ImagePrep\|ImageEditState\|ModelImageUploadSlot" lib`
   returns nothing.

---

## 4. Tests

### 4.1 Delete

The five files listed in §1.

### 4.2 Rewrite — `test/projects/model_generation_test.dart`

This file currently drives the flow THROUGH Prepare-Images: it imports
`image_prep_image_loader.dart`, overrides `prepImageLoaderProvider` with a fake
that returns a synthetic PNG (line ~119), and its `_createModel` helper taps
`prep_generate_cta` after the prep screen pushes (line ~160).

Rework it so the helper taps **`create_model_cta`** and asserts directly. These
cases must survive, unchanged in intent:

- `the CTA is hidden for a non-staff caller`
- `below 3 selected the CTA stays disabled and nothing is sent`
- `at 3 selected the CTA sends exactly the picked keys`
- `a 5th tap cannot exceed the 4-photo maximum`
- **`the same selection always yields the SAME idempotency key`** — the money
  test; keep it and keep the formula it pins
- `a failed create shows mapped copy, never a raw error` — update it to look for
  the dialog (`create_model_error`) instead of the old surface

Drop the `prepImageLoaderProvider` override, the `_FakePrepLoader`, the
`package:image` import and the PNG bytes.

### 4.3 Trim — `test/projects/repo_fake_defaults.dart`

Delete the `FakeModelImageUploadDefaults` mixin (it supplies exactly the three
repository members being removed) and remove it from every `with` clause. Any
fake repo that hand-implements those three members loses them too.

### 4.4 Add — one new case in `test/projects/preview_gallery_screen_test.dart`

`Create Model goes straight to the generation screen — no editing step`: select
three tiles, tap `create_model_cta`, assert the fake repo saw `createModel` with
those keys, assert `uploadUrlRequests == 0` if any such counter remains, and
assert the prep screen's keys (`prep_generate_cta`, `prep_save_edit`) are
`findsNothing`.

---

## 5. Hazards — read before coding

- **The idempotency key is money.** If the formula or its inputs change (order,
  separator, project id), a retry mints a NEW key and pays for a second Meshy
  generation. Sort the keys, join with `|`, prefix with the project id — exactly
  as the current code does.
- **Do not remove the backend routes in this change.** Installed builds still
  call them; deleting them turns a client-only edit into a coordinated release.
  If they are ever removed, that is a separate change gated on client rollout.
- **`fetchPhotoBytes` is the web build's CORS workaround.** It is only used by
  the prep image loader — confirm with grep before deleting, because the raw
  bucket serves no CORS and anything else that reads photo bytes on web would
  break silently.
- **Selection order is the request order.** Build `keys` by walking
  `manifest.files` and filtering on `_selected` (as above), not by iterating the
  `Set` — a Set has no meaningful order and the photo order reaching Meshy would
  become arbitrary.
- **Commit the current working tree first.** The editor (including the new
  Save/Revert work) should land as its own commit so this removal is a single,
  cleanly revertable commit.

---

## 6. Restore path

Nothing is lost: the editor lives in git history. To bring it back later —

```bash
git checkout <commit-with-the-editor> -- \
  lib/presentation/screens/projects/image_prep_screen.dart \
  lib/presentation/screens/projects/image_prep_crop_editor.dart \
  lib/application/projects/image_prep_exporter.dart \
  lib/application/projects/image_prep_image_loader.dart \
  lib/domain/entities/image_edit.dart \
  test/projects/image_prep_screen_test.dart \
  test/projects/image_prep_crop_editor_test.dart \
  test/projects/image_prep_exporter_test.dart \
  test/projects/image_prep_image_loader_test.dart \
  test/projects/image_edit_test.dart
```

…then restore the three repository members, the `image:` dependency, and the
gallery's push of `ImagePrepScreen`. Because the backend is untouched here, a
restored client works against the deployed API with no server work at all.

---

## 7. Suggested order

1. Commit the current tree (editor + Save/Revert), so this is revertable.
2. Rewrite `_createModel()` in the gallery (§2.1) and get it green against the
   existing fakes — the app now bypasses the prep screen while its files still
   exist.
3. Rework `model_generation_test.dart` (§4.2) and add the gallery case (§4.4).
4. Delete the screen + crop editor, then the exporter, loader and `image_edit`
   (§1), fixing imports as the analyzer points them out.
5. Trim the repository (§2.2) and `repo_fake_defaults.dart` (§4.3).
6. Drop the `image:` dependency (§2.3), `flutter pub get`.
7. Update `AGENTS.md` (§2.4).
8. `flutter analyze lib test` + `flutter test`, then a real device run of the
   acceptance list in §3.
