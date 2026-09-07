// lib/presentation/screens/catalog/catalog_preview_screen.dart
//
// `/catalog/preview` — the owner's draft in the shape of the public page
// (feature 5, task T-026), and the pre-flight surface the publish screen
// deep-links back into.
//
// THE PAGE ITSELF LIVES IN [CatalogPreviewPage]. What is left here is the part
// that is genuinely this screen's: where the composed draft comes from
// ([catalogPreviewProvider], which reads the OWNER's own catalog), what the app
// bar says, and where a warning's Fix button navigates to — the owner's product
// editor. The rep surface renders the same widget from its own delegated reads,
// which is the point: two renderings of "what a customer will get" is the one
// duplication a preview cannot survive.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../application/catalog/catalog_preview_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/catalog_preview_page.dart';

// Re-exported so `previewCardHeight` and the page's max width keep the import
// path they have always had. They belong to the page widget now; moving a
// public name and its callers in one change buys nothing.
export '../../widgets/catalog/catalog_preview_page.dart'
    show kPreviewPageMaxWidth, previewCardHeight;

class CatalogPreviewScreen extends ConsumerStatefulWidget {
  const CatalogPreviewScreen({super.key});

  @override
  ConsumerState<CatalogPreviewScreen> createState() =>
      _CatalogPreviewScreenState();
}

class _CatalogPreviewScreenState extends ConsumerState<CatalogPreviewScreen> {
  final _pageKey = GlobalKey<CatalogPreviewPageState>();

  Future<void> _refresh() async {
    // A refresh replaces every product object, so a viewer keyed to the old one
    // would be rebuilt mid-load. Drop back to thumbnails first.
    _pageKey.currentState?.releaseThreeD();
    await ref.read(catalogPreviewProvider.notifier).refresh();
  }

  /// Opens the product a warning is about, then re-reads: the user went there
  /// to change exactly the thing this screen is reporting on.
  Future<void> _openProduct(CatalogProduct product) async {
    await context.pushNamed(
      AppRouteNames.productDetail,
      pathParameters: {'productId': product.id},
    );
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final previewAsync = ref.watch(catalogPreviewProvider);

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
        title: Text('Preview', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: RefreshIndicator(
        color: AppColors.mirageRed,
        backgroundColor: AppColors.surface1,
        onRefresh: _refresh,
        child: previewAsync.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => CatalogMessage(
            icon: Icons.visibility_off_outlined,
            title: "We couldn't build your preview",
            body: error is CatalogFailure
                ? CatalogFeedback.failureText(error)
                : CatalogFeedback.textForCode(null),
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(catalogPreviewProvider),
          ),
          data: (preview) => CatalogPreviewPage(
            key: _pageKey,
            preview: preview,
            noticeBody: kOwnerPreviewNotice,
            onFix: _openProduct,
          ),
        ),
      ),
    );
  }
}
