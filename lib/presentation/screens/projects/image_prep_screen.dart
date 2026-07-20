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
// Errors show MAPPED copy only (failureCopy) — never a raw code or URL.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

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

/// One selected photo's session state: original bytes (never mutated), its
/// pre-rotation pixel dimensions, and the pending edit.
class _PrepImage {
  _PrepImage(this.photo);

  final PreviewPhoto photo;
  Uint8List? bytes;
  int? width;
  int? height;
  bool loadFailed = false;
  ImageEditState edit = ImageEditState.none;

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
      final bytes = await ref.read(prepImageLoaderProvider).load(image.photo);
      // Header-only decode (pure Dart, sync, cheap) — the pixel decode happens
      // on the GPU path via Image.memory and in the export isolate.
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info == null) throw const FormatException('Undecodable image');
      if (!mounted) return;
      setState(() {
        image.bytes = bytes;
        image.width = info.width;
        image.height = info.height;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => image.loadFailed = true);
    }
  }

  _PrepImage get _current => _images[_active];

  bool get _hasEdits =>
      _images.any((i) => i.edit.isEdited) ||
      _tool == _PrepTool.polygonCrop ||
      _tool == _PrepTool.rectCrop;

  bool get _cropEditorOpen =>
      _tool == _PrepTool.polygonCrop || _tool == _PrepTool.rectCrop;

  bool get _canGenerate =>
      !_generating && !_cropEditorOpen && _images.every((i) => i.isLoaded);

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Edit actions ───────────────────────────────────────────────────────────

  void _selectImage(int index) {
    if (index == _active) return;
    setState(() {
      _active = index;
      // Tools are per-image sessions — switching images closes any open one
      // rather than silently retargeting a half-finished crop.
      _tool = null;
    });
  }

  void _toggleTool(_PrepTool tool) {
    setState(() => _tool = _tool == tool ? null : tool);
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
    });
    if (_current.isTight) _snack(_tightCropCopy);
  }

  void _applyRect(RectCrop rect) {
    setState(() {
      _current.edit = _current.edit.withRect(rect.isFullImage ? null : rect);
      _tool = null;
    });
    if (_current.isTight) _snack(_tightCropCopy);
  }

  void _clearCrop() {
    setState(() => _current.edit = _current.edit.withPolygon(null));
  }

  void _setLighting(LightingAdjust lighting) {
    setState(() => _current.edit = _current.edit.withLighting(lighting));
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

  Future<void> _generate() async {
    if (!_canGenerate) return;
    setState(() => _generating = true);
    try {
      // 1. Bake every edited image to its JPEG copy (isolate per image).
      final exporter = ref.read(imagePrepExporterProvider);
      final editedIndexes = [
        for (var i = 0; i < _images.length; i++)
          if (_images[i].edit.isEdited) i,
      ];
      final exports = <int, ExportedImage>{};
      for (final i in editedIndexes) {
        exports[i] = await exporter.export(_images[i].bytes!, _images[i].edit);
      }

      // 2. Upload the copies into the job's model-input namespace; untouched
      // photos keep their original key (no re-upload).
      final finalKeys = [for (final image in _images) image.photo.key];
      if (exports.isNotEmpty) {
        final repo = ref.read(liveProjectsRepositoryProvider);
        final slots = await repo.requestModelImageUploads(
            widget.projectId, exports.length);
        var slot = 0;
        for (final entry in exports.entries) {
          await repo.uploadModelImage(slots[slot], entry.value.jpegBytes);
          finalKeys[entry.key] = slots[slot].key;
          slot++;
        }
      }

      // 3. The EXISTING create flow, unchanged — just with the mixed key list.
      final model = await ref
          .read(modelGenerationProvider(widget.projectId).notifier)
          .createModel(finalKeys,
              idempotencyKey: _idempotencyKeyFor(finalKeys));
      if (!mounted) return;
      // Session cleanup is the pop itself: bytes and edits are state of this
      // screen and are released with it.
      Navigator.of(context).pop(model);
    } on FormatException {
      _snack('One of the photos could not be processed. '
          'Remove its edits and try again.');
    } catch (e) {
      _snack(failureCopy(e));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
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
      canPop: !_hasEdits && !_generating,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _generating) return;
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
                // Re-created per image/tool so drafts never leak across.
                key: ValueKey('prep_crop_editor_${_active}_$_tool'),
                mode: _tool == _PrepTool.polygonCrop
                    ? PrepCropMode.polygon
                    : PrepCropMode.rectangle,
                initialPolygon:
                    _tool == _PrepTool.polygonCrop ? edit.polygon : null,
                initialRect: _tool == _PrepTool.rectCrop ? edit.rect : null,
                onApplyPolygon: _applyPolygon,
                onApplyRect: _applyRect,
                onCancel: () => setState(() => _tool = null),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final image = _current;
    final enabled = image.isLoaded && !_generating;
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
                    ),
                  if (image.isTight)
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
    final hint = _generating
        ? 'Preparing and uploading your edited photos…'
        : _cropEditorOpen
            ? 'Apply or cancel the crop to continue'
            : _images.any((i) => i.edit.isEdited)
                ? '${_images.where((i) => i.edit.isEdited).length} of '
                    '${_images.length} photos edited'
                : 'Editing is optional — photos are used as-is';
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          hint,
          key: const ValueKey('prep_hint'),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          key: const ValueKey('prep_generate_cta'),
          label: 'Generate 3D Model',
          icon: Icons.auto_awesome,
          isLoading: _generating,
          onPressed: _canGenerate ? _generate : null,
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
