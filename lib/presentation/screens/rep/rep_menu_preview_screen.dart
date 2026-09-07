// lib/presentation/screens/rep/rep_menu_preview_screen.dart
//
// `/rep/catalogs/:id/preview` — the restaurant's whole page as a customer will
// meet it, before the rep publishes it.
//
// THE LAST THING A REP SHOULD DO BEFORE TAPPING PUBLISH. Publishing is the one
// irreversible-feeling act of the visit: it puts a printed sticker to work, and
// whatever is on the page at that moment is what the restaurant's customers get.
// Until this screen existed the rep's only view of their work was a list of dish
// names with a status word beside each — which cannot show a missing photo, a
// dish filed into the wrong section, or a header with no logo on it.
//
// The page itself is [CatalogPreviewPage], the same widget the owner's preview
// renders. What is this screen's own is where the draft came from (four
// delegated reads, composed in [repPreviewProvider]) and where a warning's Fix
// button goes — the rep's dish editor, not the owner's.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/catalog_preview_page.dart';

/// What the rep's preview says it is.
///
/// Deliberately not [kOwnerPreviewNotice]: "your public page" is the wrong
/// possessive when the person reading is standing in someone else's restaurant,
/// and "you publish" is right — the rep is the one who will.
const String kRepPreviewNotice =
    "This is an approximation of the restaurant's public page, built from the "
    'draft — nothing here is live until you publish. The real page arranges '
    'dishes by when they were added, and shows in-stock and out-of-stock '
    'dishes the same way.';

class RepMenuPreviewScreen extends ConsumerStatefulWidget {
  const RepMenuPreviewScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<RepMenuPreviewScreen> createState() =>
      _RepMenuPreviewScreenState();
}

class _RepMenuPreviewScreenState extends ConsumerState<RepMenuPreviewScreen> {
  final _pageKey = GlobalKey<CatalogPreviewPageState>();

  Future<void> _refresh() async {
    // A refresh replaces every product object, so a viewer keyed to the old one
    // would be rebuilt mid-load. Drop back to thumbnails first.
    _pageKey.currentState?.releaseThreeD();
    await ref.read(repPreviewProvider(widget.catalogId).notifier).refresh();
  }

  /// Opens the dish a warning is about, then re-reads: the rep went there to
  /// change exactly the thing this screen is reporting on.
  Future<void> _openDish(CatalogProduct product) async {
    await context.push('/rep/catalogs/${widget.catalogId}/dishes/${product.id}');
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final previewAsync = ref.watch(repPreviewProvider(widget.catalogId));

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Menu preview')),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.mirageRed,
          backgroundColor: AppColors.surface1,
          onRefresh: _refresh,
          child: previewAsync.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (error, _) => CatalogMessage(
              icon: Icons.visibility_off_outlined,
              title: "We couldn't build the preview",
              body: isDelegationGone(error)
                  ? 'This restaurant is no longer assigned to you. Go back to '
                      'your restaurants to see what is.'
                  : error is CatalogFailure
                      ? CatalogFeedback.failureText(error)
                      : CatalogFeedback.textForCode(null),
              actionLabel: 'Try again',
              onAction: () =>
                  ref.invalidate(repPreviewProvider(widget.catalogId)),
            ),
            data: (preview) => CatalogPreviewPage(
              key: _pageKey,
              preview: preview,
              noticeBody: kRepPreviewNotice,
              onFix: _openDish,
            ),
          ),
        ),
      ),
    );
  }
}
