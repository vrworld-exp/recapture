// lib/presentation/screens/projects/image_prep_screen.dart
//
// "Prepare Images" — sits between the Preview-gallery photo selection and the
// Meshy Create-Model request. The staff user cleans each selected photo
// (polygon crop = manual background removal, rectangle crop, lighting,
// rotate) so the object reaches Meshy clean, centered and consistently lit.
// Every edit is optional; untouched photos pass through by their ORIGINAL
// key with no re-upload.
//
// On "Generate 3D Model": edited images are baked to JPEG copies
// (image_prep_exporter — the same math the preview renders), uploaded to the
// job's reserved `model-input/` namespace via presigned PUTs, and the EXISTING
// Create-Model flow runs with the mixed key list. Originals are never
// modified; session state (bytes + edits) lives only in this screen and dies
// with it. The screen POPS with the created [ProjectModelView] — the gallery
// then opens the generation status screen, exactly like before.
//
// SAVE (top-right) bakes the active photo's edits into its pixels: the saved
// version becomes THE photo for that slot — the preview shows it, the next crop
// is drawn on it, and it is what the generation uploads. It runs the same
// exporter the generation does, so "what I saved" and "what Maya AI receives"
// cannot drift apart, and its JPEG output is uploaded as-is rather than baked a
// second time. Revert restores the pristine download; S3 is untouched either
// way.
//
// THE CTA IS NEVER SILENTLY DEAD. It used to be disabled whenever a crop
// editor was open or any photo had failed to load, which — on the one screen
// whose only action is that button — reads exactly like a broken app: staff
// cropped a photo, pressed "Generate 3D Model", and nothing happened. Now the
// press always does something: an open crop draft is COMMITTED (that is what
// pressing Generate with a crop drawn means), and anything genuinely blocking
// is said out loud, with a Retry for failed loads. A failed request gets a
// dialog rather than a snackbar, because a toast at the end of a minutes-long,
// credit-spending flow is how a real failure gets reported as "nothing
// happened".
//
// Errors show MAPPED copy only (failureCopy) — never a raw code or URL.
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/image_prep_exporter.dart';
import '../../../application/projects/image_prep_image_loader.dart';
import '../../../application/projects/model_generation_notifier.dart';
import '../../../data/repositories/live_projects_repository.dart';
import '../../../domain/entities/image_edit.dart';
import '../../../domain/entities/preview_manifest.dart';
import '../../widgets/app_button.dart';
import 'image_prep_crop_editor.dart';
import 'preview_gallery_screen.dart' show failureCopy;

/// Which editing tool is active for the current image.
enum _PrepTool { polygonCrop, rectCrop, lighting }

/// One selected photo's session state: the WORKING bytes, their pre-rotation
/// DISPLAY dimensions (EXIF orientation applied — see [_load]), and the pending
/// edit measured against them.
///
/// "Save" (the app-bar action) bakes [edit] into [bytes] and clears the edit:
/// from then on the saved version IS the photo — the preview shows it, further
/// crops are drawn on it, and it is what gets uploaded for the generation. The
/// pristine download is kept in [originalBytes] so the session can be reverted;
/// the photo in S3 is never touched either way.
class _PrepImage {
  _PrepImage(this.photo);

  final PreviewPhoto photo;
  Uint8List? bytes;
  int? width;
  int? height;
  bool loadFailed = false;
  ImageEditState edit = ImageEditState.none;

  /// The untouched download, held for Revert. Set once, never overwritten.
  Uint8List? originalBytes;
  int? originalWidth;
  int? originalHeight;

  /// True once an edit has been baked into [bytes]. It is what makes a saved
  /// photo upload even though its [edit] is empty again — without it the save
  /// would silently be dropped and Meshy would receive the original.
  bool isSaved = false;

  /// Whether the SAVED pixels came out under the tight-crop floor (the pending
  /// [isTight] check can no longer see it — the crop is baked in by then).
  bool savedIsTight = false;

  /// Whether this slot must send new bytes rather than its original key.
  bool get needsUpload => isSaved || edit.isEdited;

  bool get isLoaded => bytes != null && width != null && height != null;

  /// Dimensions as displayed (rotation applied).
  ({int width, int height}) get rotatedSize => edit.quarterTurns.isOdd
      ? (width: height!, height: width!)
      : (width: width!, height: height!);

  /// Live "Very tight crop" check — the SAME crop math the export runs, so the
  /// warning on the thumbnail is exactly the export outcome.
  bool get isTight {
    if (!isLoaded) return false;
    final size = rotatedSize;
    final polygon = edit.polygon;
    if (polygon != null && polygon.length >= 3) {
      final crop = paddedPolygonCropRect(polygon, size.width, size.height);
      return isTightCrop(crop.width, crop.height);
    }
    final rect = edit.rect;
    if (rect != null && !rect.isFullImage) {
      final crop = rectCropToPixels(rect, size.width, size.height);
      return isTightCrop(crop.width, crop.height);
    }
    return false;
  }
}

class ImagePrepScreen extends ConsumerStatefulWidget {
  const ImagePrepScreen({
    super.key,
    required this.projectId,
    required this.photos,
  });

  final String projectId;

  /// The 3–4 gallery photos picked for generation, in selection order.
  final List<PreviewPhoto> photos;

  @override
  ConsumerState<ImagePrepScreen> createState() => _ImagePrepScreenState();
}

class _ImagePrepScreenState extends ConsumerState<ImagePrepScreen> {
  late final List<_PrepImage> _images = [
    for (final photo in widget.photos) _PrepImage(photo)
  ];
  int _active = 0;
  _PrepTool? _tool;
  bool _generating = false;

  /// A bake is in flight for the app-bar Save. Separate from [_generating]:
  /// the same exporter runs, but nothing leaves the device and nothing is paid
  /// for, so the two must not share a spinner or a guard.
  bool _saving = false;

  /// Reaches the OPEN crop editor so "Generate" can commit its draft (see
  /// [_generate]). A FRESH key per opening — reusing one would let a GlobalKey
  /// preserve the editor's state across images, which is exactly what the old
  /// per-image ValueKey existed to prevent.
  GlobalKey<PrepCropEditorState>? _cropEditorKey;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _images.length; i++) {
      _load(i);
    }
  }

  Future<void> _load(int index) async {
    final image = _images[index];
    if (image.loadFailed) setState(() => image.loadFailed = false);
    try {
      // The loader also MEASURES: its dimensions are EXIF-applied (what
      // Image.memory will render), which is the box every normalized crop
      // coordinate is measured against. A raw JPEG header read reports these
      // swapped on a portrait capture and silently skews the whole crop.
      final loaded = await ref
          .read(prepImageLoaderProvider)
          .load(widget.projectId, image.photo);
      if (!mounted) return;
      setState(() {
        image.bytes = loaded.bytes;
        image.width = loaded.width;
        image.height = loaded.height;
        // The pristine copy for Revert. A retry of a FAILED load re-seeds it;
        // a save never reaches here, so a saved photo keeps its true original.
        image.originalBytes = loaded.bytes;
        image.originalWidth = loaded.width;
        image.originalHeight = loaded.height;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => image.loadFailed = true);
    }
  }

  _PrepImage get _current => _images[_active];

  /// Whether anything would actually be LOST by leaving. An open crop tool is
  /// not an edit — treating it as one made Back prompt "Discard edits?" on a
  /// screen where nothing had been changed. A SAVED photo counts: its baked
  /// pixels live only in this session.
  bool get _hasEdits => _images.any((i) => i.edit.isEdited || i.isSaved);

  bool get _cropEditorOpen =>
      _tool == _PrepTool.polygonCrop || _tool == _PrepTool.rectCrop;

  List<int> get _failedIndexes => [
        for (var i = 0; i < _images.length; i++)
          if (_images[i].loadFailed) i,
      ];

  bool get _stillLoading =>
      _images.any((i) => !i.isLoaded && !i.loadFailed);

  /// Why "Generate 3D Model" cannot run right now, or null when it can.
  ///
  /// This is a MESSAGE, not a boolean, on purpose. The CTA used to be disabled
  /// whenever any of these held, which made the whole screen read as broken:
  /// the one button on it did nothing, with only a line of muted grey text
  /// saying why. Now every blocker has copy the user is actually shown, and the
  /// commonest one (an open crop editor) is not a blocker at all — [_generate]
  /// commits the draft first.
  String? get _blockReason {
    if (_failedIndexes.isNotEmpty) {
      final count = _failedIndexes.length;
      return count == _images.length
          ? 'The photos couldn’t be loaded. Tap Retry to fetch them again.'
          : '$count of ${_images.length} photos couldn’t be loaded. '
              'Tap Retry to fetch them again.';
    }
    if (_saving) return 'Saving this photo — one moment.';
    if (_stillLoading) return 'Still loading your photos — one moment.';
    return null;
  }

  /// Commits an open crop draft, the way the Apply chip would. Both Save and
  /// Generate call it first: pressing either with a crop drawn plainly means
  /// "use what I just drew". Returns false ONLY when there was a draft that
  /// cannot become a shape — and says so before it does.
  bool _commitOpenCropDraft() {
    if (!_cropEditorOpen) return true;
    final applied = _cropEditorKey?.currentState?.applyDraft() ?? false;
    if (!applied) {
      _snack('Add at least 3 points to outline the object, '
          'or cancel the outline to continue.');
      return false;
    }
    return true;
  }

  /// [duration] exists for CONFIRMATIONS: a snackbar sits over the bottom bar
  /// and swallows taps meant for the Generate button, so "Saved" must not
  /// linger for the default four seconds right where the next tap goes.
  void _snack(
    String message, {
    SnackBarAction? action,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: action,
        duration: duration,
      ));
  }

  // ── Edit actions ───────────────────────────────────────────────────────────

  void _selectImage(int index) {
    if (index == _active) return;
    setState(() {
      _active = index;
      // Tools are per-image sessions — switching images closes any open one
      // rather than silently retargeting a half-finished crop.
      _tool = null;
      _cropEditorKey = null;
    });
  }

  void _toggleTool(_PrepTool tool) {
    setState(() {
      _tool = _tool == tool ? null : tool;
      _cropEditorKey =
          _cropEditorOpen ? GlobalKey<PrepCropEditorState>() : null;
    });
  }

  /// Re-fetches every photo whose load failed. Offered from the CTA's message
  /// as well as the per-photo tile, because a failed load blocks the WHOLE
  /// screen and hunting for the broken thumbnail is not obvious.
  void _retryFailedLoads() {
    for (final index in _failedIndexes) {
      _load(index);
    }
  }

  Future<void> _rotate() async {
    final image = _current;
    final hasCrop = image.edit.polygon != null || image.edit.rect != null;
    if (hasCrop) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('prep_rotate_confirm'),
          backgroundColor: AppColors.surface1,
          title: const Text('Rotate this photo?'),
          content:
              const Text('Rotating clears the crop you applied to this photo.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Rotate'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() => image.edit = image.edit.rotatedOnce());
  }

  void _applyPolygon(List<EditPoint> points) {
    setState(() {
      _current.edit = _current.edit.withPolygon(points);
      _tool = null;
      _cropEditorKey = null;
    });
    if (_current.isTight) _snack(_tightCropCopy);
  }

  void _applyRect(RectCrop rect) {
    setState(() {
      _current.edit = _current.edit.withRect(rect.isFullImage ? null : rect);
      _tool = null;
      _cropEditorKey = null;
    });
    if (_current.isTight) _snack(_tightCropCopy);
  }

  /// Drops whichever crop shape is applied. Explicitly clears BOTH rather than
  /// relying on withPolygon(null) also nulling the rect as a side effect.
  void _clearCrop() {
    setState(() =>
        _current.edit = _current.edit.withPolygon(null).withRect(null));
  }

  void _setLighting(LightingAdjust lighting) {
    setState(() => _current.edit = _current.edit.withLighting(lighting));
  }

  // ── Save / Revert ──────────────────────────────────────────────────────────

  /// Bakes the active photo's pending edits into its pixels: from here on the
  /// saved version IS the photo — it is what the preview shows, what the next
  /// crop is drawn on, and what the generation uploads.
  ///
  /// The bake runs through the SAME exporter the generation uses, so "what I
  /// saved" and "what Meshy receives" cannot drift apart. The result is JPEG
  /// bytes, which is also exactly what the model-input upload wants, so a saved
  /// photo is uploaded as-is later rather than being re-baked.
  Future<void> _saveEdit() async {
    if (_generating || _saving) return;
    if (!_commitOpenCropDraft()) return;
    final image = _current;
    if (!image.isLoaded) {
      _snack(_blockReason ?? 'This photo isn’t ready yet.');
      return;
    }
    if (!image.edit.isEdited) {
      _snack(image.isSaved
          ? 'Already saved — this is the photo we’ll use.'
          : 'Crop, rotate or adjust the photo first, then save.');
      return;
    }
    setState(() => _saving = true);
    try {
      final exported =
          await ref.read(imagePrepExporterProvider).export(image.bytes!, image.edit);
      if (!mounted) return;
      setState(() {
        image.bytes = exported.jpegBytes;
        image.width = exported.width;
        image.height = exported.height;
        // The edit is IN the pixels now. Clearing it is what makes the next
        // crop apply to the saved result instead of re-applying to the
        // original — the "this becomes the photo" contract.
        image.edit = ImageEditState.none;
        image.isSaved = true;
        image.savedIsTight = exported.isTight;
        _tool = null;
        _cropEditorKey = null;
      });
      _snack(
        exported.isTight
            ? 'Saved — $_tightCropCopy'
            : 'Saved — this version goes to Maya AI.',
        duration: const Duration(seconds: 2),
      );
    } on FormatException {
      _showFailure(
        'This photo could not be processed. Remove its edits and try again.',
        detail: 'while saving the edit: the image could not be decoded',
      );
    } catch (e) {
      _showFailure(failureCopy(e), detail: 'while saving the edit: ${_debugKind(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Puts the pristine download back. Saving bakes pixels away permanently for
  /// the session, and a staff user who over-crops with no way back is stuck
  /// re-picking photos from the gallery.
  void _revertSaved() {
    final image = _current;
    final original = image.originalBytes;
    if (original == null) return;
    setState(() {
      image.bytes = original;
      image.width = image.originalWidth;
      image.height = image.originalHeight;
      image.edit = ImageEditState.none;
      image.isSaved = false;
      image.savedIsTight = false;
      _tool = null;
      _cropEditorKey = null;
    });
    _snack('Reverted to the original photo.',
        duration: const Duration(seconds: 2));
  }

  /// Lighting only — crop stays per-image (consistent lighting across the set
  /// matters to Meshy; a shared crop makes no sense).
  void _applyLightingToAll() {
    final lighting = _current.edit.lighting;
    setState(() {
      for (final image in _images) {
        image.edit = image.edit.withLighting(lighting);
      }
    });
    _snack('Lighting applied to all ${_images.length} photos');
  }

  // ── Generate ───────────────────────────────────────────────────────────────

  /// A stable key for one (project, final-keys) request — same replay contract
  /// as the gallery's direct flow: a double-tap of the same prepared set
  /// resolves to the SAME record server-side instead of a second paid run.
  String _idempotencyKeyFor(List<String> keys) {
    final sorted = [...keys]..sort();
    return '${widget.projectId}:${sorted.join('|')}'.hashCode.toRadixString(16);
  }

  /// Resolves whatever stands between this press and a generation, and reports
  /// whether the request may proceed. Anything that says "no" must have TOLD
  /// the user why — a press that changes nothing on screen is the bug this
  /// whole path is built around.
  bool _clearToGenerate() {
    // An open crop editor is not a blocker — commit the draft and carry on.
    // Requiring an Apply tap first is what made the CTA look dead after
    // cropping.
    if (!_commitOpenCropDraft()) return false;
    final blocked = _blockReason;
    if (blocked != null) {
      _snack(
        blocked,
        action: _failedIndexes.isEmpty
            ? null
            : SnackBarAction(label: 'Retry', onPressed: _retryFailedLoads),
      );
      return false;
    }
    return true;
  }

  Future<void> _generate() async {
    if (_generating) return;
    if (!_clearToGenerate()) return;
    setState(() => _generating = true);
    // Which of the three edited-photo-only steps we are in. Shown ONLY in debug
    // builds (see [_showFailure]): the three failures a staff user can hit here
    // — bake, model-input upload, create request — all map to the same mapped
    // copy, which is fine for them and useless for whoever has to fix it.
    var step = 'preparing the edited photos';
    try {
      // 1. Bake every image with a PENDING edit to its JPEG copy (isolate per
      // image). A saved photo whose edit is already baked in is skipped — its
      // bytes are that bake, and re-encoding them would only lose quality.
      final exporter = ref.read(imagePrepExporterProvider);
      final exports = <int, ExportedImage>{};
      for (var i = 0; i < _images.length; i++) {
        if (_images[i].edit.isEdited) {
          exports[i] = await exporter.export(_images[i].bytes!, _images[i].edit);
        }
      }

      // 2. Upload the copies into the job's model-input namespace; untouched
      // photos keep their original key (no re-upload).
      final finalKeys = [for (final image in _images) image.photo.key];
      final uploadIndexes = [
        for (var i = 0; i < _images.length; i++)
          if (_images[i].needsUpload) i,
      ];
      if (uploadIndexes.isNotEmpty) {
        final repo = ref.read(liveProjectsRepositoryProvider);
        step = 'asking the server for upload slots';
        final slots = await repo.requestModelImageUploads(
            widget.projectId, uploadIndexes.length);
        step = 'uploading the edited photos';
        var slot = 0;
        for (final i in uploadIndexes) {
          // A pending edit's fresh bake wins; otherwise these are the saved
          // pixels the user is looking at. Both are JPEG, which is what the
          // presigned PUT is signed for.
          final bytes = exports[i]?.jpegBytes ?? _images[i].bytes!;
          await repo.uploadModelImage(slots[slot], bytes);
          finalKeys[i] = slots[slot].key;
          slot++;
        }
      }

      // 3. The EXISTING create flow, unchanged — just with the mixed key list.
      step = 'requesting the model';
      final model = await ref
          .read(modelGenerationProvider(widget.projectId).notifier)
          .createModel(finalKeys,
              idempotencyKey: _idempotencyKeyFor(finalKeys));
      if (!mounted) return;
      // Session cleanup is the pop itself: bytes and edits are state of this
      // screen and are released with it.
      Navigator.of(context).pop(model);
    } on FormatException {
      _showFailure(
        'One of the photos could not be processed. '
        'Remove its edits and try again.',
        detail: 'while $step: the image could not be decoded',
      );
    } catch (e) {
      _showFailure(failureCopy(e), detail: 'while $step: ${_debugKind(e)}');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// Names the failure closely enough to act on WITHOUT quoting the server: a
  /// URL, a response body or a presigned link must never reach the screen.
  /// [LiveProjectsFailure.notFound] is the interesting one — for this flow it
  /// most often means the deployed API predates the model-input routes.
  String _debugKind(Object error) => switch (error) {
        LiveProjectsException(:final failure) => failure.name,
        _ => error.runtimeType.toString(),
      };

  /// A failed generation gets a DIALOG, not a snackbar. This is the end of a
  /// deliberate, minutes-of-work flow and the press that triggered it costs
  /// credits — a toast that fades after four seconds is how a real failure ends
  /// up reported as "nothing happened". Mapped copy only, never a raw error.
  ///
  /// [detail] names the step that failed and is shown in DEBUG BUILDS ONLY: the
  /// three edited-photo-only steps collapse into one line of user copy, which
  /// is right for staff and hopeless for diagnosis.
  Future<void> _showFailure(String message, {String? detail}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('prep_generate_error'),
        backgroundColor: AppColors.surface1,
        title: const Text('Couldn’t start the model'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (kDebugMode && detail != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                detail,
                key: const ValueKey('prep_generate_error_detail'),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('prep_generate_error_dismiss'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('prep_discard_dialog'),
        backgroundColor: AppColors.surface1,
        title: const Text('Discard edits?'),
        content: const Text(
            'Your crops and adjustments will be lost. The original photos '
            'are untouched either way.'),
        actions: [
          TextButton(
            key: const ValueKey('prep_discard_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            key: const ValueKey('prep_discard_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  static const _tightCropCopy = 'Very tight crop — result may lose detail';

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Free pop only when nothing would be lost; otherwise intercept and
      // confirm. While generating, back is ignored entirely (the request has
      // side effects a pop can't undo).
      canPop: !_hasEdits && !_generating && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _generating || _saving) return;
        _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: AppColors.bgPrimary,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: AppColors.textSecondary),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text('Prepare Images',
              style: Theme.of(context).textTheme.titleLarge),
          actions: [_saveAction()],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: _previewArea()),
              if (_tool == _PrepTool.lighting)
                _LightingPanel(
                  key: const ValueKey('prep_lighting_panel'),
                  lighting: _current.edit.lighting,
                  onChanged: _setLighting,
                  onApplyToAll: _applyLightingToAll,
                  onReset: () => _setLighting(LightingAdjust.neutral),
                ),
              _toolbar(),
              _thumbnailStrip(),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// The top-right "Save" action: bakes the active photo's edits into it.
  ///
  /// Deliberately NOT disabled when there is nothing to save — the whole point
  /// of this screen's recent history is that a silently inert control reads as
  /// a broken app. It is only inert while its own bake or a generation is
  /// running, both of which show a spinner in its place.
  Widget _saveAction() {
    if (_saving || _generating) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Center(
          child: SizedBox(
            key: ValueKey('prep_save_spinner'),
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.mirageRed),
          ),
        ),
      );
    }
    final saved = _current.isSaved && !_current.edit.isEdited;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Center(
        child: TextButton.icon(
          key: const ValueKey('prep_save_edit'),
          onPressed: _saveEdit,
          icon: Icon(saved ? Icons.check_circle : Icons.save_outlined, size: 18),
          label: Text(saved ? 'Saved' : 'Save'),
          style: TextButton.styleFrom(
            foregroundColor:
                saved ? AppColors.textMuted : AppColors.mirageRed,
          ),
        ),
      ),
    );
  }

  Widget _previewArea() {
    final image = _current;
    if (image.loadFailed) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.broken_image_outlined,
              color: AppColors.textMuted, size: 40),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Couldn’t load this photo.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label: 'Retry',
            icon: Icons.refresh,
            isFullWidth: false,
            onPressed: () => _load(_active),
          ),
        ]),
      );
    }
    if (!image.isLoaded) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.mirageRed),
      );
    }

    final size = image.rotatedSize;
    final edit = image.edit;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Center(
        child: AspectRatio(
          aspectRatio: size.width / size.height,
          child: Stack(fit: StackFit.expand, children: [
            // Lighting preview = the SAME linear map the export bakes
            // (LightingAdjust is the single source of truth for both).
            ColorFiltered(
              colorFilter: ColorFilter.matrix(edit.lighting.toColorMatrix()),
              child: RotatedBox(
                quarterTurns: edit.quarterTurns,
                // BoxFit.fill is LOAD-BEARING, not a shortcut: it guarantees
                // the image occupies exactly the same rect as the overlay
                // Stack above it, which is what makes the normalized [0,1]
                // coordinate mapping valid. BoxFit.contain would letterbox and
                // silently desynchronise the crop overlay from the pixels.
                // Since `size` above now comes from the real (EXIF-applied)
                // decode, fill and contain produce identical output anyway.
                child: Image.memory(
                  image.bytes!,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
              ),
            ),
            if (!_cropEditorOpen && (edit.polygon != null || edit.rect != null))
              IgnorePointer(
                child: CustomPaint(
                  painter: AppliedCropOverlayPainter(
                    polygon: edit.polygon,
                    rect: edit.rect,
                  ),
                ),
              ),
            if (_cropEditorOpen)
              PrepCropEditor(
                // A fresh GlobalKey per opening (see [_cropEditorKey]) — it
                // both re-creates the editor per image/tool, so drafts never
                // leak across, and lets Generate commit the open draft.
                key: _cropEditorKey,
                mode: _tool == _PrepTool.polygonCrop
                    ? PrepCropMode.polygon
                    : PrepCropMode.rectangle,
                initialPolygon:
                    _tool == _PrepTool.polygonCrop ? edit.polygon : null,
                initialRect: _tool == _PrepTool.rectCrop ? edit.rect : null,
                onApplyPolygon: _applyPolygon,
                onApplyRect: _applyRect,
                onCancel: () => setState(() {
                  _tool = null;
                  _cropEditorKey = null;
                }),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final image = _current;
    final enabled = image.isLoaded && !_generating && !_saving;
    final hasCrop = image.edit.polygon != null || image.edit.rect != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _toolButton(
            key: const ValueKey('prep_tool_polygon'),
            icon: Icons.polyline_outlined,
            label: 'Outline',
            active: _tool == _PrepTool.polygonCrop,
            onTap: enabled ? () => _toggleTool(_PrepTool.polygonCrop) : null,
          ),
          _toolButton(
            key: const ValueKey('prep_tool_rect'),
            icon: Icons.crop,
            label: 'Crop',
            active: _tool == _PrepTool.rectCrop,
            onTap: enabled ? () => _toggleTool(_PrepTool.rectCrop) : null,
          ),
          _toolButton(
            key: const ValueKey('prep_tool_lighting'),
            icon: Icons.tune,
            label: 'Light',
            active: _tool == _PrepTool.lighting,
            onTap: enabled ? () => _toggleTool(_PrepTool.lighting) : null,
          ),
          _toolButton(
            key: const ValueKey('prep_tool_rotate'),
            icon: Icons.rotate_90_degrees_cw_outlined,
            label: 'Rotate',
            active: false,
            // Rotating under an open crop editor would invalidate the draft
            // mid-gesture — close the editor first.
            onTap: enabled && !_cropEditorOpen ? _rotate : null,
          ),
          if (hasCrop && !_cropEditorOpen)
            _toolButton(
              key: const ValueKey('prep_tool_clear_crop'),
              icon: Icons.layers_clear_outlined,
              label: 'Uncrop',
              active: false,
              onTap: enabled ? _clearCrop : null,
            ),
          // Only for a SAVED photo: Uncrop cannot undo a crop that is already
          // baked into the pixels, so without this a bad save is permanent for
          // the session.
          if (image.isSaved && !_cropEditorOpen)
            _toolButton(
              key: const ValueKey('prep_tool_revert'),
              icon: Icons.restore,
              label: 'Revert',
              active: false,
              onTap: enabled ? _revertSaved : null,
            ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required Key key,
    required IconData icon,
    required String label,
    required bool active,
    VoidCallback? onTap,
  }) {
    final color = onTap == null
        ? AppColors.textMuted.withValues(alpha: 0.4)
        : active
            ? AppColors.mirageRed
            : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: AppSpacing.xs),
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: color)),
          ]),
        ),
      ),
    );
  }

  Widget _thumbnailStrip() {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: _images.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final image = _images[index];
          final selected = index == _active;
          return GestureDetector(
            key: ValueKey('prep_thumb_$index'),
            onTap: () => _selectImage(index),
            child: Container(
              width: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                border: Border.all(
                  color: selected ? AppColors.mirageRed : AppColors.surface2,
                  width: selected ? 2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs - 1),
                child: Stack(fit: StackFit.expand, children: [
                  if (image.bytes != null)
                    Image.memory(image.bytes!, fit: BoxFit.cover)
                  else
                    Container(
                      color: AppColors.surface2,
                      alignment: Alignment.center,
                      child: image.loadFailed
                          ? const Icon(Icons.broken_image_outlined,
                              size: 16, color: AppColors.textMuted)
                          : const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.textMuted),
                            ),
                    ),
                  if (image.edit.isEdited)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: Container(
                        key: ValueKey('prep_edited_badge_$index'),
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: AppColors.mirageRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.edit,
                            size: 10, color: Colors.white),
                      ),
                    )
                  // Saved and settled: a distinct mark from the pending-edit
                  // dot, so "baked in" and "not saved yet" never look alike.
                  else if (image.isSaved)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: Container(
                        key: ValueKey('prep_saved_badge_$index'),
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: AppColors.surface1,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check,
                            size: 10, color: AppColors.mirageRed),
                      ),
                    ),
                  if (image.isTight || image.savedIsTight)
                    Positioned(
                      bottom: 2,
                      right: 2,
                      child: GestureDetector(
                        key: ValueKey('prep_tight_badge_$index'),
                        onTap: () => _snack(_tightCropCopy),
                        child: const Icon(Icons.warning_amber_rounded,
                            size: 14, color: Colors.amber),
                      ),
                    ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bottomBar() {
    // A blocker is stated in WARNING colour with an icon, not as one more line
    // of muted grey — it is the difference between "the app is broken" and
    // "here is the one thing standing in your way".
    final blocked = _generating ? null : _blockReason;
    final prepared = _images.where((i) => i.needsUpload).length;
    final hint = _generating
        ? 'Preparing and uploading your edited photos…'
        : blocked ??
            (_cropEditorOpen
                ? 'Generate will apply your crop first'
                : prepared > 0
                    ? '$prepared of ${_images.length} photos edited'
                    : 'Editing is optional — photos are used as-is');
    final text = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (blocked != null) ...[
              const Icon(Icons.warning_amber_rounded,
                  size: 16, color: Colors.amber),
              const SizedBox(width: AppSpacing.xs),
            ],
            Flexible(
              child: Text(
                hint,
                key: const ValueKey('prep_hint'),
                textAlign: TextAlign.center,
                style: text?.copyWith(
                  color: blocked != null ? Colors.amber : AppColors.textMuted,
                ),
              ),
            ),
            if (_failedIndexes.isNotEmpty && !_generating) ...[
              const SizedBox(width: AppSpacing.xs),
              TextButton(
                key: const ValueKey('prep_retry_failed_loads'),
                onPressed: _retryFailedLoads,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        // Enabled whenever a request is not already in flight. Every remaining
        // blocker is handled — and SPOKEN — by _clearToGenerate; a CTA that
        // silently does nothing is the failure this screen is fixing.
        AppButton(
          key: const ValueKey('prep_generate_cta'),
          label: 'Generate 3D Model',
          icon: Icons.auto_awesome,
          isLoading: _generating,
          onPressed: _generating ? null : _generate,
        ),
      ]),
    );
  }
}

/// The lighting tool panel: brightness / contrast / warmth sliders with live
/// preview, an "apply to all" action (lighting only — consistency across the
/// set matters to Meshy) and a per-image reset.
class _LightingPanel extends StatelessWidget {
  const _LightingPanel({
    super.key,
    required this.lighting,
    required this.onChanged,
    required this.onApplyToAll,
    required this.onReset,
  });

  final LightingAdjust lighting;
  final ValueChanged<LightingAdjust> onChanged;
  final VoidCallback onApplyToAll;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface1,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _slider(
          context,
          key: const ValueKey('prep_slider_brightness'),
          label: 'Brightness',
          value: lighting.brightness,
          onChanged: (v) => onChanged(lighting.copyWith(brightness: v)),
        ),
        _slider(
          context,
          key: const ValueKey('prep_slider_contrast'),
          label: 'Contrast',
          value: lighting.contrast,
          onChanged: (v) => onChanged(lighting.copyWith(contrast: v)),
        ),
        _slider(
          context,
          key: const ValueKey('prep_slider_warmth'),
          label: 'Warmth',
          value: lighting.warmth,
          onChanged: (v) => onChanged(lighting.copyWith(warmth: v)),
        ),
        Row(children: [
          TextButton.icon(
            key: const ValueKey('prep_lighting_reset'),
            onPressed: lighting.isNeutral ? null : onReset,
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('Reset'),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('prep_lighting_apply_all'),
            onPressed: onApplyToAll,
            icon: const Icon(Icons.copy_all_outlined, size: 16),
            label: const Text('Apply to all images'),
          ),
        ]),
      ]),
    );
  }

  Widget _slider(
    BuildContext context, {
    required Key key,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(children: [
      SizedBox(
        width: 76,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: Slider(
          key: key,
          value: value,
          min: -1,
          max: 1,
          activeColor: AppColors.mirageRed,
          onChanged: onChanged,
        ),
      ),
    ]);
  }
}
