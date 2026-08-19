// lib/presentation/screens/catalog/change_product_model_screen.dart
//
// Re-point an existing 3D product at a DIFFERENT model.
//
// This is the other half of making the model an explicit choice. Picking one at
// create time is only useful if the pick can be revisited: regenerate exists
// precisely because the first result is sometimes wrong, and feedback about a
// product usually arrives after the product does. Without this screen the only
// remedy for "that's the wrong model" is deleting the product and adding it
// again.
//
// A PUSHED screen, unlike the picker on the add form — there is no form around
// it to lose the scroll position of, and it is reachable as its own URL.
//
// It renders the SAME [ModelPickerField] the add form does, deliberately: the
// capture dropdown plus the model list is the feature, and a second copy would
// drift on which records are selectable and what a pending one says.
//
// Nothing here reaches customers. `PATCH /catalog/products/:id` re-resolves
// ownership, copies the new model's artifacts onto the product and re-stamps
// `sourceProjectId`, then bumps the catalog's draft revision — the change goes
// live on the next Publish, which is what the draft sentence at the bottom
// says out loud.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../application/catalog/product_detail_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_products_repository.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/model_picker_field.dart';
import '../projects/model_viewer_screen.dart';

class ChangeProductModelScreen extends ConsumerWidget {
  const ChangeProductModelScreen({
    super.key,
    required this.productId,
    this.renderBuilder,
  });

  /// The only input. Everything else is fetched, so a browser reload on this
  /// URL behaves exactly like a push from inside the app.
  final String productId;

  /// Injectable for tests — the real viewer drives a WebView, which has no
  /// platform implementation in a widget test.
  final ModelRenderBuilder? renderBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(productDetailProvider(productId));

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Text(
          'Change 3D model',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const AppLoadingIndicator(),
          // The backend makes "no such product" and "not yours" identical on
          // purpose, so this is one state with the server's own sentence — no
          // local translation table, and never a code.
          error: (error, __) => _ChangeModelError(
            message: error is CatalogFailure
                ? error.message
                : 'Something went wrong. Please try again.',
            onRetry: () => ref.invalidate(productDetailProvider(productId)),
          ),
          data: (product) => _ChangeModelForm(
            product: product,
            renderBuilder: renderBuilder,
          ),
        ),
      ),
    );
  }
}

class _ChangeModelForm extends ConsumerStatefulWidget {
  const _ChangeModelForm({required this.product, this.renderBuilder});

  final CatalogProduct product;
  final ModelRenderBuilder? renderBuilder;

  @override
  ConsumerState<_ChangeModelForm> createState() => _ChangeModelFormState();
}

class _ChangeModelFormState extends ConsumerState<_ChangeModelForm> {
  /// Preselected on the product's OWN capture and OWN model, and both stay
  /// changeable: a user may well want a model from a completely different
  /// capture, which is a normal thing to want and not an error to prevent.
  late String? _selectedProjectId = widget.product.sourceProjectId;
  late String? _selectedModelId = widget.product.sourceModelId;

  bool _saving = false;
  String? _failureMessage;

  /// True only while the picker is showing the product's own capture.
  ///
  /// Once the user switches captures, the current model is legitimately absent
  /// from the list — that is not the "your model is gone" case, and passing the
  /// id on would make the picker claim it was.
  String? get _currentModelIdForPicker =>
      _selectedProjectId == widget.product.sourceProjectId
          ? widget.product.sourceModelId
          : null;

  /// Save means CHANGE. Nothing to save while the selection is what the product
  /// already uses, and nothing to save with no selection at all.
  bool get _canSave =>
      !_saving &&
      _selectedModelId != null &&
      _selectedModelId != widget.product.sourceModelId;

  /// Same direct push as the add form and the owner model history: never the
  /// `modelViewer` named route (it resolves the record from the STAFF
  /// provider), no approve, no regenerate, no optimize.
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

  Future<void> _save() async {
    final modelId = _selectedModelId;
    if (_saving || modelId == null) return;

    setState(() {
      _saving = true;
      _failureMessage = null;
    });

    try {
      final updated = await ref
          .read(catalogProductsRepositoryProvider)
          .update(widget.product.id, sourceModelId: modelId);
      if (!mounted) return;

      // The header's counts and its "unpublished changes" badge are both
      // server-derived, and this write moved the draft revision. Refresh rather
      // than guessing — awaited but not fatal, since the product HAS changed.
      try {
        await ref.read(catalogProvider.notifier).refresh();
      } catch (_) {/* the next pull-to-refresh reconciles it */}
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${updated.name} now uses the model you picked. '
            'Customers will see this after you publish.',
          ),
        ),
      );
      navigateBack(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // MODEL_NOT_FOUND and MODEL_NOT_READY both already carry owner-safe
        // copy from the backend. Anything else gets one plain fallback.
        _failureMessage = error is CatalogFailure
            ? error.message
            : 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = widget.product;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        // Same rule as the add form: the column is the readable width on a
        // monitor and the full width on a phone, decided by the constraints.
        constraints: const BoxConstraints(maxWidth: kModelPickerMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          children: [
            Text(product.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Pick a different model for this product. Its files are copied '
              'onto the product when you save.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.xxl),
            ModelPickerField(
              selectedProjectId: _selectedProjectId,
              selectedModelId: _selectedModelId,
              currentModelId: _currentModelIdForPicker,
              enabled: !_saving,
              onProjectChanged: (projectId) => setState(() {
                _selectedProjectId = projectId;
                // Cleared with the capture, exactly as on the add form: a model
                // id from the previous capture must never reach the PATCH.
                _selectedModelId = null;
                _failureMessage = null;
              }),
              onModelChanged: (modelId) => setState(() {
                _selectedModelId = modelId;
                _failureMessage = null;
              }),
              onPreview: _openModelPreview,
            ),
            if (_failureMessage != null) ...[
              const SizedBox(height: AppSpacing.xxl),
              Text(
                _failureMessage!,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.error),
              ),
            ],
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: _saving ? 'Saving…' : 'Save',
              isLoading: _saving,
              // Disabled until the pick actually differs — a Save that writes
              // the model the product already has is a draft revision bump and
              // an "unpublished changes" badge for nothing.
              onPressed: _canSave ? _save : null,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'This is a draft edit. Customers will see this after you publish.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChangeModelError extends StatelessWidget {
  const _ChangeModelError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
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
}
