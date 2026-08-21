// lib/presentation/screens/catalog/product_editor_screen.dart
//
// One product's editor (features 14, 15, 16, 17, 18).
//
// Reached by id and nothing else, so a browser reload on `/catalog/products/:id`
// behaves exactly like a push from the grid — the same rule the change-model
// screen follows, and the reason `extra` is never used to carry the product.
//
// What this screen is careful about, in order of how badly it goes wrong:
//   • It never implies an edit is already public. Every write here is a DRAFT
//     edit; the live catalog only moves on Publish (feature 57).
//   • It never re-uploads an image it has already uploaded. A commit that fails
//     after a successful upload retries the COMMIT.
//   • It never loses typed work silently — in-app back, browser back and tab
//     close all warn.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_categories_notifier.dart';
import '../../../application/catalog/product_detail_notifier.dart';
import '../../../data/datasources/product_image_picker.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_products_repository.dart'
    show kCatalogUnchanged;
import '../../../domain/entities/catalog_category.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_availability.dart';
import '../../../domain/entities/product_sync_status.dart';
import '../../../domain/entities/product_type.dart';
import '../../../platform/unsaved_changes.dart';
import '../../../utils/price_format.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/app_status_pill.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/model_picker_field.dart' show kModelPickerMaxWidth;

/// Width at or above which the form splits into two columns.
///
/// From the CONSTRAINTS, never `kIsWeb`: a narrow browser window gets the phone
/// layout and a wide tablet gets the two-column one.
const double kProductEditorTwoColumnWidth = 900;

/// Whether the editor currently holds unsaved edits.
///
/// A provider rather than screen state because the ROUTER needs to read it: the
/// browser's back button is a router event, not a widget one, and go_router's
/// `onExit` runs with no access to the screen's State. Kept honest by the
/// editor, which clears it on dispose.
final productEditorDirtyProvider = StateProvider<bool>((ref) => false);

class ProductEditorScreen extends ConsumerStatefulWidget {
  const ProductEditorScreen({super.key, required this.productId});

  final String productId;

  @override
  ConsumerState<ProductEditorScreen> createState() =>
      _ProductEditorScreenState();
}

class _ProductEditorScreenState extends ConsumerState<ProductEditorScreen> {
  /// Captured while the element is still ATTACHED.
  ///
  /// `ProviderScope.containerOf` walks the element tree, and doing that from
  /// `dispose()` is an ancestor lookup on a deactivated widget — an assertion,
  /// not a warning. The container itself outlives this screen, so holding the
  /// reference is safe where looking it up later is not.
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    // The flag outlives the widget BY DESIGN — the router reads it from
    // `onExit` — so it has to be cleared here, or the next navigation inherits
    // a stale "you have unsaved changes" and asks about edits that are gone.
    final container = _container;
    if (container != null) {
      // Post-frame: a provider write during dispose is a Riverpod error. The
      // container can be gone by then (the whole scope torn down at once), and
      // that is not a failure — there is nothing left to keep honest.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          container.read(productEditorDirtyProvider.notifier).state = false;
        } catch (_) {/* scope already disposed */}
      });
    }
    setUnsavedChangesWarning(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(productDetailProvider(widget.productId));

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => _confirmThenLeave(context),
        ),
        title: Text(
          'Edit product',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          // "No such product" and "not yours" are identical at the API boundary
          // on purpose, so this is ONE state carrying the server's own sentence.
          error: (error, __) => _EditorError(
            message: error is CatalogFailure
                ? error.message
                : 'Something went wrong. Please try again.',
            onRetry: () =>
                ref.invalidate(productDetailProvider(widget.productId)),
          ),
          data: (product) => _ProductEditorForm(
            key: ValueKey(product.id),
            product: product,
          ),
        ),
      ),
    );
  }
}

/// Asks before discarding typed work. True means "go ahead and leave".
///
/// Takes a [BuildContext] and nothing else, deliberately: the app-bar arrow, the
/// system back gesture AND go_router's browser-back `onExit` all have one of
/// those and only the first two have a `WidgetRef`. One function means all three
/// exits ask the same question in the same words, which is the whole point of a
/// guard — an exit that forgets to ask is the one the user loses work through.
Future<bool> confirmDiscardProductEdits(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!container.read(productEditorDirtyProvider)) return true;

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
          child: Text('Discard', style: TextStyle(color: AppColors.error)),
        ),
      ],
    ),
  );

  if (discard != true) return false;
  container.read(productEditorDirtyProvider.notifier).state = false;
  setUnsavedChangesWarning(false);
  return true;
}

Future<void> _confirmThenLeave(BuildContext context) async {
  if (!await confirmDiscardProductEdits(context)) return;
  if (!context.mounted) return;
  navigateBack(context);
}

class _ProductEditorForm extends ConsumerStatefulWidget {
  const _ProductEditorForm({super.key, required this.product});

  final CatalogProduct product;

  @override
  ConsumerState<_ProductEditorForm> createState() => _ProductEditorFormState();
}

class _ProductEditorFormState extends ConsumerState<_ProductEditorForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.product.name);
  late final TextEditingController _description =
      TextEditingController(text: widget.product.description ?? '');
  late final TextEditingController _price = TextEditingController(
    text: widget.product.price == null ? '' : _priceText(widget.product.price!),
  );
  final TextEditingController _tagInput = TextEditingController();

  late String? _categoryId = widget.product.categoryId;
  late ProductAvailability _availability = widget.product.availability;
  late bool _featured = widget.product.featured;
  late List<String> _tags = [...widget.product.tags];

  String? _failureMessage;

  /// Set when an image uploaded but its commit failed, so the retry offered is
  /// "finish", not "upload again".
  bool _imageCommitPending = false;

  ProductDetailNotifier get _notifier =>
      ref.read(productDetailProvider(widget.product.id).notifier);

  @override
  void initState() {
    super.initState();
    for (final controller in [_name, _description, _price]) {
      controller.addListener(_recomputeDirty);
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _description, _price, _tagInput]) {
      controller.dispose();
    }
    super.dispose();
  }

  // ── Dirty tracking ────────────────────────────────────────────────────────

  bool get _nameChanged => _name.text.trim() != widget.product.name;
  bool get _descriptionChanged =>
      _description.text.trim() != (widget.product.description ?? '');
  bool get _priceChanged => _parsedPrice() != widget.product.price;
  bool get _categoryChanged => _categoryId != widget.product.categoryId;
  bool get _tagsChanged =>
      _tags.join(' ') != widget.product.tags.join(' ');
  bool get _availabilityChanged => _availability != widget.product.availability;
  bool get _featuredChanged => _featured != widget.product.featured;

  bool get _isDirty =>
      _nameChanged ||
      _descriptionChanged ||
      _priceChanged ||
      _categoryChanged ||
      _tagsChanged ||
      _availabilityChanged ||
      _featuredChanged;

  /// Publishes the dirty flag outward — to the router's browser-back guard and
  /// to the browser's own tab-close prompt.
  void _recomputeDirty() {
    final dirty = _isDirty;
    if (ref.read(productEditorDirtyProvider) == dirty) return;
    ref.read(productEditorDirtyProvider.notifier).state = dirty;
    setUnsavedChangesWarning(dirty);
    setState(() {}); // the Save button and the dirty markers follow it
  }

  double? _parsedPrice() {
    final raw = _price.text.trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  static String _priceText(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_isDirty) return;

    setState(() => _failureMessage = null);

    try {
      // Only what CHANGED goes out. A patch that resends every field would bump
      // the draft revision for an edit nobody made, and light up the
      // "unpublished changes" badge for it.
      final updated = await _notifier.save(
        name: _nameChanged ? _name.text.trim() : null,
        description: _descriptionChanged ? _description.text.trim() : null,
        // Sentinels: an explicitly null price CLEARS it, which is different from
        // not touching the field, and different again from a price of 0.
        price: _priceChanged ? _parsedPrice() : kCatalogUnchanged,
        categoryId: _categoryChanged ? _categoryId : kCatalogUnchanged,
        tags: _tagsChanged ? _tags : null,
        availability: _availabilityChanged ? _availability : null,
        featured: _featuredChanged ? _featured : null,
      );
      if (!mounted) return;

      ref.read(productEditorDirtyProvider.notifier).state = false;
      setUnsavedChangesWarning(false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${updated.name} saved. Customers see this after you publish.',
          ),
        ),
      );
      // The form is rebuilt from the server's product by the ValueKey on the
      // parent, so the fields re-seed and nothing is left marked dirty.
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failureMessage = failure.message);
    }
  }

  Future<void> _replaceImage() async {
    setState(() => _failureMessage = null);
    try {
      final picked =
          await ref.read(productImagePickerProvider).pickProductImage();
      if (picked == null || !mounted) return; // cancelled

      await _notifier.replaceImage(
        picked.bytes,
        contentType: picked.contentType,
      );
      if (!mounted) return;
      setState(() => _imageCommitPending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo replaced.')),
      );
    } on ProductImagePickException catch (error) {
      if (!mounted) return;
      setState(() => _failureMessage = error.message);
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        // The bytes may already be in the bucket. If they are, the retry is a
        // commit and the user is not asked to send 5 MiB twice.
        _imageCommitPending = _notifier.uncommittedImageKey != null;
        _failureMessage = failure.message;
      });
    }
  }

  Future<void> _retryCommit() async {
    setState(() => _failureMessage = null);
    try {
      await _notifier.retryCommitImage();
      if (!mounted) return;
      setState(() => _imageCommitPending = false);
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failureMessage = failure.message);
    }
  }

  Future<void> _changeModel() async {
    // Leaving for the model picker is leaving: unsaved field edits would not
    // survive the round trip, so it asks the same question the back arrow does.
    if (!await confirmDiscardProductEdits(context)) return;
    if (!mounted) return;

    await context.pushNamed(
      AppRouteNames.productModel,
      pathParameters: {'productId': widget.product.id},
    );
    if (!mounted) return;
    await _notifier.refresh();
  }

  Future<void> _duplicate() async {
    setState(() => _failureMessage = null);
    try {
      final copy = await _notifier.duplicate();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Duplicated as "${copy.name}".')),
      );
      // Straight to the copy: a duplicate the user cannot see is a duplicate
      // they press again. pushReplacement, so back still lands on the grid
      // rather than on the product they came from.
      ref.read(productEditorDirtyProvider.notifier).state = false;
      setUnsavedChangesWarning(false);
      if (!mounted) return;
      context.pushReplacementNamed(
        AppRouteNames.productDetail,
        pathParameters: {'productId': copy.id},
      );
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() => _failureMessage = failure.message);
    }
  }

  // ── Tags ──────────────────────────────────────────────────────────────────

  void _addTag(String raw) {
    // Lower-cased and de-duplicated to match the server's own normalisation, so
    // what the user sees here is what will be stored.
    final tag = raw.trim().toLowerCase();
    if (tag.isEmpty) return;
    if (tag.length > kMaxProductTagLength) {
      setState(() => _failureMessage =
          'Tags can be at most $kMaxProductTagLength characters.');
      return;
    }
    if (_tags.length >= kMaxProductTags) {
      setState(() =>
          _failureMessage = 'You can add at most $kMaxProductTags tags.');
      return;
    }
    if (_tags.contains(tag)) {
      _tagInput.clear();
      return;
    }
    setState(() {
      _tags = [..._tags, tag];
      _failureMessage = null;
    });
    _tagInput.clear();
    _recomputeDirty();
  }

  void _removeTag(String tag) {
    setState(() => _tags = [..._tags]..remove(tag));
    _recomputeDirty();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The save step is a ValueNotifier rather than provider state: an
    // `AsyncValue` that flipped to loading mid-save would blank the very form
    // being saved.
    return ValueListenableBuilder<ProductSaveStep>(
      valueListenable: _notifier.step,
      builder: (context, saveStep, _) {
        final busy = saveStep != ProductSaveStep.idle;
        return PopScope(
          // The system back gesture and the Android hardware button. The browser
          // back button does NOT come through here — that is the router's
          // onExit — and closing a tab comes through neither, which is what the
          // platform seam is for.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            await _confirmThenLeave(context);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final twoColumn =
                  constraints.maxWidth >= kProductEditorTwoColumnWidth;
              final asset = _AssetPanel(
                product: widget.product,
                busy: busy,
                saveStep: saveStep,
                commitPending: _imageCommitPending,
                onReplaceImage: _replaceImage,
                onRetryCommit: _retryCommit,
                onChangeModel: _changeModel,
              );
              final fields = _fieldColumn(context, busy: busy, step: saveStep);

              if (!twoColumn) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.screenPadding),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: kModelPickerMaxWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          asset,
                          const SizedBox(height: AppSpacing.xxl),
                          fields,
                        ],
                      ),
                    ),
                  ),
                );
              }

              return SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 2, child: asset),
                        const SizedBox(width: AppSpacing.xxl),
                        Expanded(flex: 3, child: fields),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _fieldColumn(
    BuildContext context, {
    required bool busy,
    required ProductSaveStep step,
  }) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LiveStateBanner(product: widget.product, dirty: _isDirty),
          const SizedBox(height: AppSpacing.xxl),
          _DirtyLabel(
            label: 'Product name',
            changed: _nameChanged,
            child: AppTextField(
              label: 'Product name',
              controller: _name,
              enabled: !busy,
              maxLength: kMaxProductNameLength,
              textInputAction: TextInputAction.next,
              validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Give this product a name.'
                  : null,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _DirtyLabel(
            label: 'Price',
            changed: _priceChanged,
            child: AppTextField(
              // The currency is the CATALOG's, not this product's: the update
              // endpoint accepts no currency field, so offering to change it
              // here would be offering something the server will not do.
              label: 'Price in ${widget.product.currency} (optional)',
              controller: _price,
              enabled: !busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              textInputAction: TextInputAction.next,
              validator: (value) {
                final raw = (value ?? '').trim();
                if (raw.isEmpty) return null; // clearing it is legitimate
                final parsed = double.tryParse(raw);
                if (parsed == null) return 'Enter a number, like 249 or 249.50';
                if (parsed < 0) return 'A price cannot be negative.';
                return null;
              },
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            // Blank is a real value, and it is not zero. Saying so here is
            // cheaper than a support message asking why the card says "free".
            _price.text.trim().isEmpty
                ? 'Leave this empty for no price. The card will say "No price '
                    'set" rather than "Free".'
                : 'Shown to customers as '
                    '${formatPrice(_parsedPrice(), widget.product.currency) ?? '—'}.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),
          _DirtyLabel(
            label: 'Description',
            changed: _descriptionChanged,
            child: AppTextField(
              label: 'Description (optional)',
              controller: _description,
              enabled: !busy,
              maxLength: kMaxProductDescriptionLength,
              maxLines: 4,
              minLines: 2,
              textInputAction: TextInputAction.newline,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _CategoryField(
            categoryId: _categoryId,
            changed: _categoryChanged,
            enabled: !busy,
            onChanged: (id) {
              setState(() => _categoryId = id);
              _recomputeDirty();
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          _TagField(
            tags: _tags,
            controller: _tagInput,
            enabled: !busy,
            changed: _tagsChanged,
            onAdd: _addTag,
            onRemove: _removeTag,
          ),
          const SizedBox(height: AppSpacing.lg),
          _AvailabilityField(
            value: _availability,
            enabled: !busy,
            onChanged: (value) {
              setState(() => _availability = value);
              _recomputeDirty();
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _featured,
            onChanged: busy
                ? null
                : (value) {
                    setState(() => _featured = value);
                    _recomputeDirty();
                  },
            title: Text('Featured', style: theme.textTheme.titleMedium),
            subtitle: Text(
              'Visible to you only — featured products sort to the front of '
              'your catalog here, and change nothing customers see.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ),
          if (_failureMessage != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              _failureMessage!,
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.error),
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),
          AppButton(
            label: switch (step) {
              ProductSaveStep.uploadingImage => 'Uploading photo…',
              ProductSaveStep.committingImage => 'Finishing…',
              ProductSaveStep.saving => 'Saving…',
              ProductSaveStep.idle => 'Save changes',
            },
            isLoading: busy,
            // Disabled with nothing to save: a Save that writes what is already
            // stored is a draft-revision bump and an "unpublished changes"
            // badge for nothing.
            onPressed: _isDirty && !busy ? _save : null,
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton.secondary(
            label: 'Duplicate product',
            icon: Icons.copy_all_outlined,
            onPressed: busy ? null : _duplicate,
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
    );
  }
}

/// What is live, and what is not.
///
/// Deliberately says LESS than a field-by-field "this differs from live" diff
/// would: the product DTO carries `syncStatus` but not the published snapshot's
/// values, so a per-field live comparison would be invented. What can be said
/// truthfully is said — whether this product is live at all, and that saved
/// edits wait for the next publish.
class _LiveStateBanner extends StatelessWidget {
  const _LiveStateBanner({required this.product, required this.dirty});

  final CatalogProduct product;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, message) = switch (product.syncStatus) {
      ProductSyncStatus.synced => (
          Icons.public,
          AppColors.success,
          'This product is live. Anything you save here goes live at your next '
              'publish.',
        ),
      ProductSyncStatus.failed => (
          Icons.error_outline,
          AppColors.error,
          product.syncError ??
              'The last publish could not update this product. Fix it here, '
                  'then publish again.',
        ),
      ProductSyncStatus.pending => (
          Icons.sync,
          AppColors.royalGold,
          'A publish is running. Edits you save now are not part of it — they '
              'go live at the publish after it.',
        ),
      _ => (
          Icons.edit_note,
          AppColors.textMuted,
          'This product has never been published. It goes live the first time '
              'you publish your catalog.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          if (dirty) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.circle,
                    size: 8, color: AppColors.warning),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Unsaved changes',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.warning),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A field plus a marker showing it differs from what is SAVED.
class _DirtyLabel extends StatelessWidget {
  const _DirtyLabel({
    required this.label,
    required this.changed,
    required this.child,
  });

  final String label;
  final bool changed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          child,
          if (changed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 6, color: AppColors.warning),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Not saved yet',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.warning),
                  ),
                ],
              ),
            ),
        ],
      );
}

/// The product's backing asset, and the two ways to change it.
class _AssetPanel extends StatelessWidget {
  const _AssetPanel({
    required this.product,
    required this.busy,
    required this.saveStep,
    required this.commitPending,
    required this.onReplaceImage,
    required this.onRetryCommit,
    required this.onChangeModel,
  });

  final CatalogProduct product;
  final bool busy;
  final ProductSaveStep saveStep;
  final bool commitPending;
  final VoidCallback onReplaceImage;
  final VoidCallback onRetryCommit;
  final VoidCallback onChangeModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final threeD = product.type.supportsThreeD;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: AspectRatio(
            aspectRatio: 1,
            child: product.thumbnailUrl == null
                ? Container(
                    color: AppColors.surface1,
                    alignment: Alignment.center,
                    child: Icon(
                      threeD ? Icons.view_in_ar_outlined : Icons.image_outlined,
                      size: 40,
                      color: AppColors.textMuted,
                    ),
                  )
                : Image.network(
                    product.thumbnailUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: AppColors.surface1,
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported_outlined,
                          size: 32, color: AppColors.textMuted),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            SyncStatusPill(status: product.syncStatus, showWhenNeverPublished: true),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                product.type.label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (saveStep == ProductSaveStep.uploadingImage ||
            saveStep == ProductSaveStep.committingImage) ...[
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.royalGold),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                saveStep == ProductSaveStep.uploadingImage
                    ? 'Uploading photo…'
                    : 'Finishing…',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (commitPending) ...[
          Text(
            // The bytes are already stored. Re-uploading them would be charging
            // the user for our failed second call.
            'Your photo uploaded but could not be attached. Nothing needs '
            're-uploading — try finishing it.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.warning),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Finish attaching photo',
            icon: Icons.refresh,
            onPressed: busy ? null : onRetryCommit,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (threeD)
          AppButton.secondary(
            label: 'Change 3D model',
            icon: Icons.view_in_ar_outlined,
            onPressed: busy ? null : onChangeModel,
          )
        else ...[
          AppButton.secondary(
            label: 'Replace photo',
            icon: Icons.add_photo_alternate_outlined,
            onPressed: busy ? null : onReplaceImage,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            label: 'Use a 3D model instead',
            icon: Icons.view_in_ar_outlined,
            onPressed: busy ? null : onChangeModel,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            // Feature 17. A conversion changes what a customer sees, so it is
            // named as such before it is offered, not after it is done.
            'Switching to a 3D model replaces this photo everywhere, including '
            'on your public catalog at the next publish.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// The category picker, including the Uncategorized bucket.
class _CategoryField extends ConsumerWidget {
  const _CategoryField({
    required this.categoryId,
    required this.changed,
    required this.enabled,
    required this.onChanged,
  });

  final String? categoryId;
  final bool changed;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories =
        ref.watch(catalogCategoriesProvider).valueOrNull?.categories ??
            const <CatalogCategory>[];

    // A category deleted while this editor was open would leave the dropdown
    // with a value that is not among its items — an assertion, not a warning —
    // so an id we no longer recognise falls back to Uncategorized, which is
    // exactly where the server put the product.
    final known = categories.any((c) => c.id == categoryId);
    final value = known ? categoryId : null;

    return _DirtyLabel(
      label: 'Category',
      changed: changed,
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Category'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: value,
            isExpanded: true,
            dropdownColor: AppColors.surface1,
            onChanged: enabled ? onChanged : null,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Uncategorized'),
              ),
              for (final category in categories)
                DropdownMenuItem<String?>(
                  value: category.id,
                  child: Text(
                    category.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tag chips plus an input, bounded exactly as the server bounds them.
class _TagField extends StatelessWidget {
  const _TagField({
    required this.tags,
    required this.controller,
    required this.enabled,
    required this.changed,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> tags;
  final TextEditingController controller;
  final bool enabled;
  final bool changed;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _DirtyLabel(
      label: 'Tags',
      changed: changed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tags.isNotEmpty) ...[
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final tag in tags)
                  Chip(
                    label: Text(tag),
                    backgroundColor: AppColors.surface1,
                    side: BorderSide(
                      color: AppColors.textMuted.withValues(alpha: 0.3),
                    ),
                    onDeleted: enabled ? () => onRemove(tag) : null,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppTextField(
            label: 'Add a tag',
            hint: 'e.g. bestseller',
            controller: controller,
            enabled: enabled && tags.length < kMaxProductTags,
            maxLength: kMaxProductTagLength,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: onAdd,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Visible to you only — tags do not appear on your public catalog. '
            '${tags.length} of $kMaxProductTags used.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
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
  Widget build(BuildContext context) => Column(
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
            selected: {
              value == ProductAvailability.unknown
                  ? ProductAvailability.inStock
                  : value
            },
            onSelectionChanged:
                enabled ? (selection) => onChanged(selection.first) : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          // Feature 8c is ReCapture-ONLY, and the editor is required to say so
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
      );
}

class _EditorError extends StatelessWidget {
  const _EditorError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined,
                  color: AppColors.textMuted, size: 40),
              const SizedBox(height: AppSpacing.lg),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Retry',
                icon: Icons.refresh,
                isFullWidth: false,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      );
}
