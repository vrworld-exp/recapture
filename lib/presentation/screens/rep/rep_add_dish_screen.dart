// lib/presentation/screens/rep/rep_add_dish_screen.dart
//
// One dish, authored on a restaurant's behalf, from whichever source this build
// can offer.
//
// THREE SOURCES, AND ONE OF THEM IS PLATFORM-GATED:
//   • CAPTURE NOW      — shoot the dish, then pick the capture that comes back.
//                        MOBILE ONLY. A browser has no capture pipeline (not
//                        merely no camera — no exposure, stability, IMU or
//                        permission channels), so this source is ABSENT there,
//                        never disabled.
//   • FROM A CAPTURE   — a capture already finished. Both targets.
//   • PHOTO            — image only, no AR. Both targets.
//
// The first two converge: both produce a THREE_D dish carrying a
// `sourceModelId`, and differ only in whether the rep shoots first. That is why
// "capture now" hands straight over to the same picker rather than owning a
// second submit path — one way to build a 3D dish, two ways to reach it.
//
// WHOSE CAPTURE IS IT. The rep shoots on their own phone, so the Project is the
// REP's while the catalog is the RESTAURANT's. `POST /rep/catalogs/:id/products`
// widens model ownership by exactly the calling rep so the two can meet; the
// dish that comes back belongs to the restaurant. Nothing here has to know
// that, but a reader wondering why a rep's model is linkable at all should see
// `catalogProductsService.resolveOwnedModel`.
//
// No HTTP here — RepRepository owns it, and failures are read by CODE and
// answered with this screen's own words, exactly as the activation screen does.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_capabilities.dart';
import '../../../data/datasources/product_image_picker.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/rep_repository.dart';
import '../../../domain/entities/product_type.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/model_picker_field.dart';

/// Which source the rep is authoring from. Distinct from [ProductType] on
/// purpose: `captureNow` and `fromCapture` both END in a `threeD` product, and
/// collapsing them here would lose the one distinction the platform gate needs.
enum RepDishSource { captureNow, fromCapture, photo }

class RepAddDishScreen extends ConsumerStatefulWidget {
  const RepAddDishScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<RepAddDishScreen> createState() => _RepAddDishScreenState();
}

class _RepAddDishScreenState extends ConsumerState<RepAddDishScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  RepDishSource _source = RepDishSource.fromCapture;
  String? _selectedProjectId;
  String? _selectedModelId;
  PickedProductImage? _image;
  String? _failureMessage;
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// The sources this build can offer, in the order they are shown.
  ///
  /// Built from the capability rather than filtered afterwards, so the web list
  /// genuinely has two entries — a hidden-but-present option is the state this
  /// stage exists to avoid.
  List<RepDishSource> _sourcesFor(RepCapabilities caps) => [
        if (caps.canCaptureDish) RepDishSource.captureNow,
        RepDishSource.fromCapture,
        RepDishSource.photo,
      ];

  Future<void> _captureNow() async {
    // The UNMODIFIED capture entry point — the same one an owner uses. It
    // returns when the flow is done and the new capture then appears in the
    // picker below, newest first.
    await context.push(AppRoutes.preCapture);
    if (!mounted) return;
    setState(() {
      _source = RepDishSource.fromCapture;
      _failureMessage = null;
    });
  }

  Future<void> _pickImage() async {
    setState(() => _failureMessage = null);
    try {
      final picked =
          await ref.read(productImagePickerProvider).pickProductImage();
      if (picked == null || !mounted) return; // cancelled
      setState(() => _image = picked);
    } on ProductImagePickException catch (error) {
      if (!mounted) return;
      setState(() => _failureMessage = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _failureMessage =
            "That image couldn't be read. Please choose another.",
      );
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // The asset is not a form field, so the validator above cannot catch its
    // absence — but it is the one thing the server will certainly refuse.
    if (_source == RepDishSource.photo && _image == null) {
      setState(() => _failureMessage = 'Choose a photo for this dish.');
      return;
    }
    if (_source != RepDishSource.photo && _selectedModelId == null) {
      setState(() => _failureMessage = 'Choose the capture for this dish.');
      return;
    }

    setState(() {
      _submitting = true;
      _failureMessage = null;
    });

    final repo = ref.read(repRepositoryProvider);
    try {
      String? imageKey;
      if (_source == RepDishSource.photo) {
        // Upload FIRST: an image-only dish is created WITH its key, so there is
        // no product to scope the upload to yet.
        imageKey = await repo.uploadImageBytes(
          widget.catalogId,
          _image!.bytes,
          contentType: _image!.contentType,
        );
      }

      await repo.createProduct(
        widget.catalogId,
        type: _source == RepDishSource.photo
            ? ProductType.imageOnly
            : ProductType.threeD,
        name: _nameController.text.trim(),
        sourceModelId: _source == RepDishSource.photo ? null : _selectedModelId,
        imageKey: imageKey,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _failureMessage = _copyFor(failure.code);
      });
    }
  }

  /// THIS screen's words for a failure code. The backend's message is never
  /// shown — it cannot name the dish in front of the rep and never says what to
  /// do next.
  String _copyFor(String code) => switch (code) {
        'MODEL_NOT_READY' =>
          'That capture is still processing. Pick another, or wait a moment.',
        'MODEL_NOT_FOUND' => 'That capture is no longer available.',
        'DUPLICATE_NAME' =>
          'This restaurant already has a dish with that name.',
        'CATALOG_NOT_FOUND' =>
          'You can no longer edit this restaurant. Ask for access again.',
        'PAYLOAD_TOO_LARGE' => 'That photo is too large. Choose a smaller one.',
        'UNSUPPORTED_MEDIA_TYPE' =>
          'That file is not a JPEG, PNG or WebP photo.',
        'RATE_LIMITED' => 'Too many uploads just now. Wait a minute.',
        'OFFLINE' => "You're offline. Check your connection and try again.",
        _ => 'Something went wrong. Try again in a moment.',
      };

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(repCapabilitiesProvider);
    final sources = _sourcesFor(caps);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Add a dish')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              _SourcePicker(
                sources: sources,
                selected: _source,
                enabled: !_submitting,
                onChanged: (source) async {
                  if (source == RepDishSource.captureNow) {
                    await _captureNow();
                    return;
                  }
                  setState(() {
                    _source = source;
                    _failureMessage = null;
                  });
                },
              ),
              const SizedBox(height: AppSpacing.xxl),

              if (_source == RepDishSource.photo)
                _PhotoField(
                  image: _image,
                  enabled: !_submitting,
                  onPick: _pickImage,
                  onClear: () => setState(() => _image = null),
                )
              else
                ModelPickerField(
                  selectedProjectId: _selectedProjectId,
                  selectedModelId: _selectedModelId,
                  enabled: !_submitting,
                  onProjectChanged: (projectId) => setState(() {
                    _selectedProjectId = projectId;
                    // Cleared in the SAME setState as the capture — a model id
                    // from the previous capture reaching a submit is the one
                    // bug this field can introduce.
                    _selectedModelId = null;
                    _failureMessage = null;
                  }),
                  onModelChanged: (modelId) => setState(() {
                    _selectedModelId = modelId;
                    _failureMessage = null;
                  }),
                  onPreview: (_) {},
                ),

              const SizedBox(height: AppSpacing.xxl),
              AppTextField(
                key: const ValueKey('rep_dish_name_field'),
                label: 'Dish name',
                hint: 'e.g. Paneer Tikka',
                controller: _nameController,
                enabled: !_submitting,
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Give this dish a name.'
                    : null,
              ),

              if (_failureMessage != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  _failureMessage!,
                  key: const ValueKey('rep_dish_failure'),
                  style: const TextStyle(
                    fontSize: AppTypography.sizeCaption,
                    color: AppColors.error,
                  ),
                ),
              ],

              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                key: const ValueKey('rep_dish_submit'),
                label: 'Add dish',
                isLoading: _submitting,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The source list. Renders exactly what it is given — the platform gate lives
/// in the parent, so this widget has no opinion about which target it is on.
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({
    required this.sources,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final List<RepDishSource> sources;
  final RepDishSource selected;
  final bool enabled;
  final ValueChanged<RepDishSource> onChanged;

  static ({IconData icon, String label, String caption}) _optionFor(
    RepDishSource source,
  ) =>
      switch (source) {
        RepDishSource.captureNow => (
            icon: Icons.add_a_photo_outlined,
            label: 'Capture now',
            caption: 'Shoot this dish for AR',
          ),
        RepDishSource.fromCapture => (
            icon: Icons.view_in_ar_outlined,
            label: '3D model',
            caption: 'From a finished capture',
          ),
        RepDishSource.photo => (
            icon: Icons.photo_outlined,
            label: 'Photo',
            caption: 'Image only — no AR',
          ),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final source in sources) ...[
          Builder(
            builder: (context) {
              final option = _optionFor(source);
              final isSelected = source == selected;
              return InkWell(
                key: ValueKey('rep_dish_source_${source.name}'),
                onTap: enabled ? () => onChanged(source) : null,
                borderRadius: BorderRadius.circular(AppSpacing.sm),
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppSpacing.sm),
                    border: Border.all(
                      color: isSelected
                          ? AppColors.royalGold
                          : AppColors.surface2,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(option.icon, color: AppColors.textSecondary),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              option.label,
                              style: const TextStyle(
                                fontSize: AppTypography.sizeBody,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              option.caption,
                              style: const TextStyle(
                                fontSize: AppTypography.sizeCaption,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

/// The image-only source's field: pick, show, clear.
class _PhotoField extends StatelessWidget {
  const _PhotoField({
    required this.image,
    required this.enabled,
    required this.onPick,
    required this.onClear,
  });

  final PickedProductImage? image;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (image == null) {
      return AppButton.secondary(
        key: const ValueKey('rep_dish_pick_photo'),
        label: 'Choose a photo',
        icon: Icons.photo_outlined,
        onPressed: enabled ? onPick : null,
      );
    }
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSpacing.sm),
          child: Image.memory(
            image!.bytes,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: const Text(
            'Photo selected',
            style: TextStyle(
              fontSize: AppTypography.sizeBody,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('rep_dish_clear_photo'),
          onPressed: enabled ? onClear : null,
          child: const Text('Change'),
        ),
      ],
    );
  }
}
