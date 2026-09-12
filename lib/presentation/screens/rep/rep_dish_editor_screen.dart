// lib/presentation/screens/rep/rep_dish_editor_screen.dart
//
// One dish on a delegated restaurant: what a customer will see, and the form
// that changes it.
//
// THE PREVIEW IS THE POINT, AND IT IS LIVE. The card at the top is the same
// [PreviewProductCard] the public-page preview renders, fed the dish AS THE
// FORM CURRENTLY READS IT rather than as the server last saved it. A rep
// typing a name watches the card change under their thumb, which answers the
// question they actually have — "is this what the restaurant will see on the
// table?" — before they save rather than after they publish.
//
// DELIBERATELY NARROWER THAN THE OWNER'S EDITOR. No archive, no delete, no
// duplicate, no model swap, no tags, no featured star. (The menu SECTION is
// here, and can now be created from here — see [RepSectionPicker]. That is not
// a widening of scope so much as the removal of a dead end: a rep-activated
// restaurant has no sections at all, so a picker that could only choose among
// existing ones could only ever choose Uncategorized.) Those either have no
// delegated route behind them or are decisions about a catalog the restaurant
// lives with long after the visit; a rep changes what is wrong on the table in
// front of them. The fields that ARE here are the ones a rep is asked to fix
// while standing in the room: the name, what it is, what it costs, whether the
// kitchen has it, and the photo.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/rep/rep_dish_notifier.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/datasources/product_image_picker.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_products_repository.dart'
    show kCatalogUnchanged;
import '../../../domain/catalog/catalog_names.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_availability.dart';
import '../../../domain/entities/product_food_type.dart';
import '../../../domain/entities/product_type.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/food_type_field.dart';
import '../../widgets/catalog/preview_product_card.dart';
import '../../widgets/rep/rep_section_picker.dart';

/// Width at or above which the preview sits BESIDE the form instead of above
/// it.
///
/// From the CONSTRAINTS, never `kIsWeb` — the same rule and the same number the
/// owner's editor uses, so a narrow browser window gets the phone layout and a
/// wide tablet gets the desktop one.
const double kRepDishEditorTwoColumnWidth = 900;

/// How tall the preview card is here.
///
/// Fixed rather than derived from the viewport the way the full-page preview
/// does it: there is exactly ONE card on this screen, so the "about two cards
/// per screen" rhythm the public page was designed around has nothing to say.
const double kRepDishPreviewHeight = 260;

class RepDishEditorScreen extends ConsumerWidget {
  const RepDishEditorScreen({
    super.key,
    required this.catalogId,
    required this.productId,
  });

  final String catalogId;
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dishRef = (catalogId: catalogId, productId: productId);
    final dishAsync = ref.watch(repDishProvider(dishRef));

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Edit dish')),
      body: SafeArea(
        child: dishAsync.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => CatalogMessage(
            icon: Icons.no_meals_outlined,
            title: "We couldn't open that dish",
            body: isDelegationGone(error)
                ? 'This restaurant is no longer assigned to you. Go back to '
                    'your restaurants to see what is.'
                : error is CatalogFailure
                    ? CatalogFeedback.failureText(error)
                    : CatalogFeedback.textForCode(null),
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(repDishProvider(dishRef)),
          ),
          // Keyed by the dish id ALONE, deliberately. The product object is
          // replaced on every save, and keying on `updatedAt` would rebuild the
          // form — throwing away text the rep had typed but not saved — every
          // time a write came back. The controllers are the rep's; only a SAVE
          // re-seeds them.
          data: (dish) => _DishForm(
            key: ValueKey<String>(dish.id),
            catalogId: catalogId,
            dish: dish,
          ),
        ),
      ),
    );
  }
}

class _DishForm extends ConsumerStatefulWidget {
  const _DishForm({super.key, required this.catalogId, required this.dish});

  final String catalogId;
  final CatalogProduct dish;

  @override
  ConsumerState<_DishForm> createState() => _DishFormState();
}

class _DishFormState extends ConsumerState<_DishForm> {
  final _formKey = GlobalKey<FormState>();

  // The DISPLAY form. Seeding with the stored slug ("chicken_biryani") is what
  // made reps retype the name — and a retype normalises back to what is already
  // stored, so the save changed nothing while the screen said it had.
  late final _name = TextEditingController(text: widget.dish.displayName);
  late final _description =
      TextEditingController(text: widget.dish.description ?? '');
  late final _price = TextEditingController(
    text: widget.dish.price == null ? '' : _priceText(widget.dish.price!),
  );

  late String? _categoryId = widget.dish.categoryId;
  late ProductAvailability _availability = widget.dish.availability;
  late ProductFoodType _foodType = widget.dish.foodType;

  /// The photo the rep picked but has not saved yet.
  ///
  /// Held as BYTES as well as a key: the bytes are what the preview card can
  /// render immediately, and the key is what the save sends. Showing the old
  /// photo next to a "Photo ready to save" line would be the one thing this
  /// screen must not do — claim the card is current when it is not.
  Uint8List? _pendingImageBytes;
  String? _pendingImageKey;

  bool _saving = false;
  bool _pickingImage = false;
  CatalogFailure? _failure;

  RepDishRef get _ref =>
      (catalogId: widget.catalogId, productId: widget.dish.id);

  RepDishNotifier get _notifier => ref.read(repDishProvider(_ref).notifier);

  @override
  void initState() {
    super.initState();
    for (final controller in [_name, _description, _price]) {
      controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _description, _price]) {
      controller
        ..removeListener(_onChanged)
        ..dispose();
    }
    super.dispose();
  }

  // The live preview and the Save button both read the field values, so every
  // keystroke has to repaint. Cheap: one card and one button.
  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ── What changed ──────────────────────────────────────────────────────────

  double? _parsedPrice() {
    final raw = _price.text.trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  static String _priceText(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  /// Compared as SLUGS — the field holds the display form and the dish holds
  /// the stored one, so raw equality is dirty from the moment the screen opens.
  bool get _nameChanged => catalogNameChanged(
        _name.text,
        widget.dish.name,
        maxLength: kMaxProductNameLength,
      );
  bool get _descriptionChanged =>
      _description.text.trim() != (widget.dish.description ?? '');
  bool get _priceChanged => _parsedPrice() != widget.dish.price;
  bool get _categoryChanged => _categoryId != widget.dish.categoryId;
  bool get _availabilityChanged => _availability != widget.dish.availability;
  bool get _foodTypeChanged => _foodType != widget.dish.foodType;

  bool get _isDirty =>
      _nameChanged ||
      _descriptionChanged ||
      _priceChanged ||
      _categoryChanged ||
      _availabilityChanged ||
      _foodTypeChanged ||
      _pendingImageKey != null;

  /// The dish as the FORM currently reads it — what the preview card renders.
  ///
  /// Built from the saved dish so everything the form does not touch (the model
  /// urls, the thumbnail, the sync status) stays real. An invalid price is
  /// simply not applied: the card keeps the last good one rather than blanking
  /// while someone types "12.".
  CatalogProduct get _draft => widget.dish.copyWith(
        name: _name.text.trim().isEmpty ? widget.dish.name : _name.text.trim(),
        description: _description.text.trim(),
        price: _price.text.trim().isEmpty ? null : _parsedPrice(),
        categoryId: _categoryId,
        availability: _availability,
        foodType: _foodType,
      );

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Picks a replacement photo and uploads it, WITHOUT binding it.
  ///
  /// The binding happens in [_save] with the rest of the form, so a rep who
  /// fixes the name and the photo together sends one write and cannot end up
  /// with half of it applied. A failed save keeps the key, so the retry is the
  /// save and never a second upload of the same bytes.
  Future<void> _pickPhoto() async {
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _pickingImage = true;
      _failure = null;
    });

    try {
      final PickedProductImage? picked;
      try {
        picked = await ref.read(productImagePickerProvider).pickProductImage();
      } on ProductImagePickException catch (error) {
        // The rep's problem to fix, and it is fixable — say which of the three
        // it was rather than "upload failed".
        if (mounted) CatalogFeedback.confirm(messenger, error.message);
        return;
      }
      if (picked == null) return; // cancelled

      final key = await _notifier.uploadImage(
        picked.bytes,
        contentType: picked.contentType,
      );
      if (!mounted) return;
      setState(() {
        _pendingImageBytes = picked!.bytes;
        _pendingImageKey = key;
      });
    } on CatalogFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_isDirty) return;

    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _failure = null;
    });

    try {
      // Only what CHANGED goes out. A patch that resent every field would bump
      // the draft revision for an edit nobody made, and light up the
      // "not live yet" line for it.
      await _notifier.save(
        name: _nameChanged ? _name.text.trim() : null,
        description: _descriptionChanged ? _description.text.trim() : null,
        // Sentinels: an explicitly null price CLEARS it, which is different
        // from not touching the field, and different again from a price of 0.
        price: _priceChanged ? _parsedPrice() : kCatalogUnchanged,
        categoryId: _categoryChanged ? _categoryId : kCatalogUnchanged,
        availability: _availabilityChanged ? _availability : null,
        foodType: _foodTypeChanged ? _foodType : null,
        imageKey: _pendingImageKey,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        // The upload is spent — the server has the key on the dish now, and a
        // second save must not re-send it.
        _pendingImageBytes = null;
        _pendingImageKey = null;
      });
      CatalogFeedback.confirm(
        messenger,
        'Dish saved. Publish the menu to put the change in front of customers.',
      );
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failure = failure;
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: const Text('Discard your changes?'),
        content: const Text(
          "You have edits that haven't been saved. Leaving now loses them.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Discard',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The system back gesture and the Android hardware button. A rep who has
      // typed a price and swiped back must not lose it silently.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!await _confirmDiscard()) return;
        if (!context.mounted) return;
        navigateBack(context);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn =
              constraints.maxWidth >= kRepDishEditorTwoColumnWidth;
          final preview = _previewColumn(context);
          final form = _formColumn(context);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: twoColumn
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: preview),
                          const SizedBox(width: AppSpacing.xxl),
                          Expanded(flex: 3, child: form),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          preview,
                          const SizedBox(height: AppSpacing.xxl),
                          form,
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _previewColumn(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('What a customer will see', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          _pendingImageKey != null
              ? 'Including the new photo. Nothing here reaches customers until '
                  'you save and publish.'
              : 'An approximation of the card on the published menu. Nothing '
                  'here reaches customers until you publish.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: AppSpacing.lg),
        PreviewProductCard(
          key: const ValueKey('rep_dish_preview_card'),
          product: _draft,
          height: kRepDishPreviewHeight,
          // The picked bytes, so the card shows what the rep just chose rather
          // than the photo it is replacing. Null until they pick one, and the
          // card falls back to the stored image.
          overrideImageBytes: _pendingImageBytes,
        ),
      ],
    );
  }

  Widget _formColumn(BuildContext context) {
    final categoriesAsync =
        ref.watch(repCategoriesProvider(widget.catalogId));

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            key: const ValueKey('rep_dish_name'),
            label: 'Dish name',
            controller: _name,
            enabled: !_saving,
            maxLength: 120,
            textInputAction: TextInputAction.next,
            validator: (value) => (value ?? '').trim().isEmpty
                ? "Enter the dish's name."
                : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            key: const ValueKey('rep_dish_description'),
            label: 'Description (optional)',
            controller: _description,
            enabled: !_saving,
            maxLength: 2000,
            maxLines: 4,
            minLines: 2,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            key: const ValueKey('rep_dish_price'),
            label: 'Price (optional)',
            controller: _price,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            validator: (value) {
              final raw = (value ?? '').trim();
              if (raw.isEmpty) return null;
              final parsed = double.tryParse(raw);
              if (parsed == null) return 'Enter a number, like 250.';
              if (parsed < 0) return 'A price cannot be negative.';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Leave this empty for no price. The card will say "No price set".',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.xxl),

          // ── Veg / non-veg ─────────────────────────────────────────────────
          // The one row here that customers DO see — the preview card above
          // redraws its marker as the rep taps.
          Text('Veg / non-veg', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          FoodTypeField(
            fieldKey: const ValueKey('rep_dish_food_type'),
            showLabel: false,
            value: _foodType,
            enabled: !_saving,
            onChanged: (value) => setState(() => _foodType = value),
          ),
          const SizedBox(height: AppSpacing.xxl),

          // ── Section ───────────────────────────────────────────────────────
          Text('Menu section', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          categoriesAsync.when(
            // A section list that has not arrived must never look like "this
            // restaurant has no sections" — that would invite a rep to move a
            // dish to Uncategorized by accident.
            loading: () => const _InlineNote('Loading sections…'),
            error: (_, __) => const _InlineNote(
              "Couldn't load the sections. The dish keeps the one it has.",
            ),
            data: (list) => RepSectionPicker(
              fieldKey: const ValueKey('rep_dish_section'),
              catalogId: widget.catalogId,
              categories: list.categories,
              value: _categoryId,
              enabled: !_saving,
              onChanged: (value) => setState(() => _categoryId = value),
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),

          // ── Availability ──────────────────────────────────────────────────
          Text('Kitchen', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          SwitchListTile(
            key: const ValueKey('rep_dish_in_stock'),
            contentPadding: EdgeInsets.zero,
            value: _availability != ProductAvailability.outOfStock,
            onChanged: _saving
                ? null
                : (value) => setState(
                      () => _availability = value
                          ? ProductAvailability.inStock
                          : ProductAvailability.outOfStock,
                    ),
            title: const Text('Available today'),
            // The honest caveat, in the same words the owner's editor uses:
            // Mirage's item schema has no availability field, so this never
            // reaches the published page.
            subtitle: Text(
              'Kept in ReCapture only — the published menu shows every dish '
              'the same way.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),

          // ── Photo ─────────────────────────────────────────────────────────
          Text('Photo', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (widget.dish.type == ProductType.threeD)
            const _InlineNote(
              "This dish's card image comes from its 3D capture, so there is no "
              'photo to replace here.',
            )
          else ...[
            AppButton.secondary(
              key: const ValueKey('rep_dish_replace_photo'),
              label: _pendingImageKey == null
                  ? 'Replace photo'
                  : 'Choose a different photo',
              icon: Icons.photo_camera_outlined,
              isLoading: _pickingImage,
              onPressed: _saving || _pickingImage ? null : _pickPhoto,
            ),
            if (_pendingImageKey != null) ...[
              const SizedBox(height: AppSpacing.sm),
              const _InlineNote(
                'New photo uploaded. It replaces the old one when you save.',
              ),
            ],
          ],

          if (_failure != null) ...[
            const SizedBox(height: AppSpacing.xxl),
            _SaveError(failure: _failure!),
          ],

          const SizedBox(height: AppSpacing.xxl),
          AppButton(
            key: const ValueKey('rep_dish_save'),
            label: 'Save dish',
            isLoading: _saving,
            onPressed: _saving || !_isDirty ? null : _save,
          ),
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.textSecondary, height: 1.4),
      );
}

class _SaveError extends StatelessWidget {
  const _SaveError({required this.failure});

  final CatalogFailure failure;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, size: 16, color: AppColors.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                // OUR sentence for the code, from the one table — never the
                // server's own message, never Mirage's prose, never an HTTP
                // status.
                CatalogFeedback.failureText(failure),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.error, height: 1.4),
              ),
            ),
          ],
        ),
      );
}
