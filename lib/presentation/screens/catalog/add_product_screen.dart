// lib/presentation/screens/catalog/add_product_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/product_create_notifier.dart';
import '../../../data/datasources/product_image_picker.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/product_availability.dart';
import '../../../domain/entities/product_type.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/model_picker_field.dart';
import '../projects/model_viewer_screen.dart';

/// Hand-synced with `createProductSchema` in
/// `recapture-api/src/validation/catalogSchemas.ts` (there is no shared package
/// — see AGENTS.md §0.1). Enforced here only so an over-long value is caught
/// before the round-trip; the server remains the authority.
const int kProductNameMaxLength = 120;
const int kProductDescriptionMaxLength = 2000;

/// Add a product to the draft catalog (features 6, 7, 11, 12, 13).
///
/// TWO sources, because the backend accepts exactly two and each REQUIRES its
/// own asset: a 3D product needs a finished model the caller owns, and an
/// image-only product needs an uploaded image. There is no third "just a name
/// and a price" product — the server rejects it, so the form never offers it.
///
/// Nothing here reaches customers. This is a draft edit like every other write
/// on this surface; the live catalog only moves on Publish (feature 57).
///
/// A full screen rather than the dialog the catalog CREATE uses: this form
/// carries an image preview and a project list, which a 360-wide dialog cannot
/// hold on a phone without becoming a scroll-within-a-scroll.
class AddProductScreen extends ConsumerStatefulWidget {
  const AddProductScreen({super.key, this.renderBuilder});

  /// How a previewed model is rendered. Injectable for tests only — the real
  /// renderer drives a WebView, which has no platform implementation in a
  /// widget test. Null means the viewer's own default.
  final ModelRenderBuilder? renderBuilder;

  @override
  ConsumerState<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends ConsumerState<AddProductScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _descriptionController = TextEditingController();

  ProductType _type = ProductType.threeD;
  ProductAvailability _availability = ProductAvailability.inStock;
  bool _featured = false;

  /// The capture whose model backs a 3D product. A capture is what the user
  /// recognises; it is the way IN to the models, not the answer.
  String? _selectedProjectId;

  /// THE ANSWER: which of that capture's models this product will use.
  ///
  /// Real state, not derived from the project. It used to be a getter that read
  /// whatever single model `GET /projects/:id` called the latest — which,
  /// per AGENTS.md, silently becomes the `optimized` record once one succeeds.
  /// A user who regenerated because the first result was wrong had no way to
  /// say which result they meant. Now they pick it, and this holds the pick.
  ///
  /// Cleared with [_selectedProjectId] on every capture change: a model id
  /// belonging to the PREVIOUS capture reaching [_submit] is the one bug this
  /// feature could introduce, so it is made structurally impossible rather than
  /// checked for.
  String? _selectedModelId;

  PickedProductImage? _image;

  /// The last failure's owner-safe sentence, shown above the actions. Cleared on
  /// every new attempt so a stale message never sits under a request that is
  /// succeeding.
  String? _failureMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Opens one model in the 3D viewer and comes straight back.
  ///
  /// The call shape is copied from `owner_model_history_screen.dart` on
  /// purpose: a DIRECT push, never the `modelViewer` named route, because that
  /// route resolves the record out of the STAFF provider and an owner only ever
  /// 403s on it. No approve (staff-only), no regenerate and no optimize — the
  /// picker's only jobs are select and preview, and a new pending record
  /// appearing mid-form is a distraction nobody asked for.
  ///
  /// Nothing here touches form state, so returning leaves the selection, the
  /// scroll position and every typed field exactly as they were.
  void _openModelPreview(ProjectModelView model) {
    if (!model.isViewable) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(
          model: model,
          title: 'Preview',
          onRegenerate: null,
          onOptimize: null,
          renderBuilder:
              widget.renderBuilder ?? ModelViewerScreen.defaultRenderBuilder,
        ),
      ),
    );
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
    final notifier = ref.read(productCreateProvider.notifier);
    if (notifier.isSubmitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // The asset is not a form field, so its absence cannot be caught by the
    // validator above — but it is the one thing the server will certainly
    // reject, so it is checked in the same breath.
    final sourceModelId = _type == ProductType.threeD ? _selectedModelId : null;
    if (_type == ProductType.threeD && sourceModelId == null) {
      setState(
        () =>
            _failureMessage = 'Choose which 3D model this product should use.',
      );
      return;
    }
    if (_type == ProductType.imageOnly && _image == null) {
      setState(() => _failureMessage = 'Add a photo for this product.');
      return;
    }

    setState(() => _failureMessage = null);

    final description = _descriptionController.text.trim();

    try {
      final product = await notifier.submit(
        type: _type,
        name: _nameController.text.trim(),
        // Absent, not empty — the server schema is strict and rejects a blank
        // description.
        description: description.isEmpty ? null : description,
        price: _parsedPrice(),
        availability: _availability,
        featured: _featured ? true : null,
        sourceModelId: sourceModelId,
        imageBytes: _image?.bytes,
        imageContentType: _image?.contentType,
      );
      if (!mounted) return;

      CatalogFeedback.confirm(
        CatalogFeedback.of(context),
        '${product.name} was added to your catalog.',
      );
      navigateBack(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // Mapped from the CODE, never from the server's own sentence — the one
        // table, so this banner reads the way the toasts do. Anything that is
        // not a CatalogFailure has no code at all and gets the same generic
        // fallback an unknown code would.
        _failureMessage = error is CatalogFailure
            ? CatalogFeedback.failureText(error)
            : CatalogFeedback.textForCode(null);
      });
    }
  }

  /// The typed price as a number, or null when the field is blank.
  ///
  /// Blank is a legitimate "no price", distinct from 0 — the field is optional
  /// on the server and an unpriced product is a normal catalog entry.
  double? _parsedPrice() {
    final raw = _priceController.text.trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = ref.watch(productCreateProvider);
    final submitting = step != ProductCreateStep.idle;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          // Null while submitting: leaving mid-create would strand an upload
          // the user could not see the result of.
          onPressed: submitting ? null : () => navigateBack(context),
        ),
        title: Text('Add product', style: theme.textTheme.titleLarge),
      ),
      body: SafeArea(
        // The form is a single column of controls, and a 1200-point-wide
        // browser window would stretch every one of them across the monitor —
        // including the model tiles, whose thumbnail and Preview button would
        // end up at opposite ends of the screen. Decided from the CONSTRAINTS
        // (a ConstrainedBox that simply does nothing on a phone), never from
        // `kIsWeb`: a small browser window is a phone layout.
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kModelPickerMaxWidth),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                children: [
                  _SourceSelector(
                    type: _type,
                    enabled: !submitting,
                    onChanged: (type) => setState(() {
                      _type = type;
                      _failureMessage = null;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  if (_type == ProductType.threeD)
                    _FieldShell(
                      label: '3D model',
                      child: ModelPickerField(
                        selectedProjectId: _selectedProjectId,
                        selectedModelId: _selectedModelId,
                        enabled: !submitting,
                        onProjectChanged: (projectId) => setState(() {
                          _selectedProjectId = projectId;
                          // Cleared IN THE SAME setState as the capture. See
                          // [_selectedModelId].
                          _selectedModelId = null;
                          _failureMessage = null;
                        }),
                        onModelChanged: (modelId) => setState(() {
                          _selectedModelId = modelId;
                          _failureMessage = null;
                        }),
                        onPreview: _openModelPreview,
                      ),
                    )
                  else
                    _ImageSourceField(
                      image: _image,
                      enabled: !submitting,
                      onPick: _pickImage,
                      onClear: () => setState(() => _image = null),
                    ),
                  const SizedBox(height: AppSpacing.xxl),
                  AppTextField(
                    label: 'Product name',
                    hint: 'e.g. Paneer Tikka',
                    controller: _nameController,
                    enabled: !submitting,
                    maxLength: kProductNameMaxLength,
                    textInputAction: TextInputAction.next,
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Give this product a name.'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppTextField(
                    label: 'Price (optional)',
                    hint: 'e.g. 249',
                    controller: _priceController,
                    enabled: !submitting,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    // Digits and at most one dot. The keyboard type is a HINT on
                    // web and on some Android IMEs — a desktop browser hands over a
                    // full hardware keyboard regardless — so the formatter is what
                    // actually holds the field to a number.
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      final raw = (value ?? '').trim();
                      if (raw.isEmpty) return null; // optional
                      final parsed = double.tryParse(raw);
                      if (parsed == null) {
                        return 'Enter a number, like 249 or 249.50';
                      }
                      if (parsed < 0) return 'A price cannot be negative.';
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppTextField(
                    label: 'Description (optional)',
                    hint: 'What customers should know about it',
                    controller: _descriptionController,
                    enabled: !submitting,
                    maxLength: kProductDescriptionMaxLength,
                    maxLines: 4,
                    minLines: 2,
                    textInputAction: TextInputAction.newline,
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  _AvailabilityField(
                    value: _availability,
                    enabled: !submitting,
                    onChanged: (value) => setState(() => _availability = value),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _FeaturedField(
                    value: _featured,
                    enabled: !submitting,
                    onChanged: (value) => setState(() => _featured = value),
                  ),
                  if (_failureMessage != null) ...[
                    const SizedBox(height: AppSpacing.xxl),
                    Text(
                      _failureMessage!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.error),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xxl),
                  AppButton(
                    // The upload is the slow half of an image create, so it gets its
                    // own label — one undifferentiated spinner over a 5 MiB upload
                    // reads as a hang.
                    label: switch (step) {
                      ProductCreateStep.uploadingImage => 'Uploading photo…',
                      ProductCreateStep.creating => 'Adding…',
                      ProductCreateStep.idle => 'Add product',
                    },
                    isLoading: submitting,
                    onPressed: _submit,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'This is a draft edit. Customers see it after you publish.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 3D vs image-only. A segmented pair rather than a dropdown: there are exactly
/// two, and which one is chosen changes the field below it, so both options stay
/// visible.
class _SourceSelector extends StatelessWidget {
  const _SourceSelector({
    required this.type,
    required this.enabled,
    required this.onChanged,
  });

  final ProductType type;
  final bool enabled;
  final ValueChanged<ProductType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SourceOption(
            icon: Icons.view_in_ar_outlined,
            label: '3D model',
            caption: 'From a finished capture',
            selected: type == ProductType.threeD,
            enabled: enabled,
            onTap: () => onChanged(ProductType.threeD),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: _SourceOption(
            icon: Icons.photo_outlined,
            label: 'Photo',
            caption: 'Image only — no AR',
            selected: type == ProductType.imageOnly,
            enabled: enabled,
            onTap: () => onChanged(ProductType.imageOnly),
          ),
        ),
      ],
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.label,
    required this.caption,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String caption;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = selected ? AppColors.royalGold : AppColors.textMuted;

    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.royalGold.withValues(alpha: 0.08)
                : AppColors.surface1,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: accent.withValues(alpha: selected ? 0.6 : 0.2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accent, size: 24),
              const SizedBox(height: AppSpacing.sm),
              Text(label, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                caption,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picks and previews the photo an image-only product is built from.
class _ImageSourceField extends StatelessWidget {
  const _ImageSourceField({
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
    final theme = Theme.of(context);
    final picked = image;

    return _FieldShell(
      label: 'Photo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Memory, not a file path: on WEB the picker hands back a blob with no
          // filesystem path at all, so bytes are the one source both builds have.
          if (picked != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.memory(
                picked.bytes,
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
                // The bytes passed a magic-byte sniff, which says what the file
                // CLAIMS to be, not that its pixels decode. A truncated or
                // corrupt photo would otherwise throw out of the image service
                // and take the form down with it, so the preview degrades
                // instead — Add product stays pressable, and the server does
                // the last word on whether the bytes are usable.
                errorBuilder: (context, _, __) => Container(
                  height: 180,
                  color: AppColors.surface1,
                  alignment: Alignment.center,
                  child: Text(
                    "This photo can't be previewed.",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                ),
              ),
            )
          else
            InkWell(
              onTap: enabled ? onPick : null,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  color: AppColors.surface1,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: AppColors.royalGold.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.add_photo_alternate_outlined,
                        color: AppColors.textMuted, size: 32),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Choose a photo',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              if (picked != null) ...[
                TextButton(
                  onPressed: enabled ? onPick : null,
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: enabled ? onClear : null,
                  child: Text(
                    'Remove',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                const Spacer(),
                Text(
                  _sizeLabel(picked.length),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ] else
                Expanded(
                  child: Text(
                    'JPEG, PNG or WebP, up to 5 MB.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _AvailabilityField extends StatelessWidget {
  const _AvailabilityField({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final ProductAvailability value;
  final bool enabled;
  final ValueChanged<ProductAvailability> onChanged;

  @override
  Widget build(BuildContext context) {
    return _FieldShell(
      label: 'Availability',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<ProductAvailability>(
            segments: const [
              ButtonSegment(
                value: ProductAvailability.inStock,
                label: Text('In stock'),
              ),
              ButtonSegment(
                value: ProductAvailability.outOfStock,
                label: Text('Out of stock'),
              ),
            ],
            selected: {value},
            onSelectionChanged:
                enabled ? (selection) => onChanged(selection.first) : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          // Feature 8c is ReCapture-ONLY and the editor is required to say so
          // rather than implying customers see it.
          Text(
            'Visible to you only — the public catalog shows an out-of-stock '
            'product exactly like an in-stock one.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _FeaturedField extends StatelessWidget {
  const _FeaturedField({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: enabled ? onChanged : null,
        title: Text('Featured', style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          'Featured products sort to the front of your catalog.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
      );
}

/// A labelled block. One wrapper so the source fields, availability and the rest
/// cannot drift apart visually.
class _FieldShell extends StatelessWidget {
  const _FieldShell({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      );
}
