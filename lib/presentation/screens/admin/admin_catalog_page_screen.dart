// lib/presentation/screens/admin/admin_catalog_page_screen.dart
//
// `/admin/catalogs/:id` — one restaurant's page, as the ADMIN opens it from
// "All catalogs".
//
// THE SAME PAGE EVERY CATALOG HAS: [CatalogPreviewPage], the widget the owner's
// and the rep's previews render, fed by the rep surface's delegated reads
// ([repPreviewProvider]) — the server's /rep gate admits an ADMIN for any live
// catalog, so there is no third data path to drift.
//
// THE BANNER IS THE DOOR TO EDITING. Tapping it (or the app bar's Edit) opens
// the rep editor for this catalog — dishes, sections, restaurant details,
// branding — and Publish there sends the changes live. Nothing on this screen
// writes; it re-reads when the admin comes back.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../application/catalog/catalog_link_service.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/catalog_preview_page.dart';

/// What the admin's page says it is. Not the owner's "your page" nor the rep's
/// "the restaurant you are standing in" — and it says how to edit.
const String kAdminCatalogPageNotice =
    "This is this restaurant's page as built from its current draft — an "
    'approximation of the live menu. Tap the banner to edit it; nothing '
    'changes for customers until you publish from the editor.';

class AdminCatalogPageScreen extends ConsumerStatefulWidget {
  const AdminCatalogPageScreen({
    super.key,
    required this.catalogId,
    this.initialTitle,
  });

  final String catalogId;

  /// The name from the card that was tapped, so the app bar is not blank while
  /// the page loads. Null on a deep link; the loaded catalog's name replaces it.
  final String? initialTitle;

  @override
  ConsumerState<AdminCatalogPageScreen> createState() =>
      _AdminCatalogPageScreenState();
}

class _AdminCatalogPageScreenState
    extends ConsumerState<AdminCatalogPageScreen> {
  final _pageKey = GlobalKey<CatalogPreviewPageState>();

  /// Guards a double tap on the banner pushing the editor twice.
  bool _opening = false;

  String get _editorBase => '${AppRoutes.repCatalogs}/${widget.catalogId}';

  Future<void> _refresh() async {
    // A refresh replaces every product object; a 3D viewer keyed to the old one
    // would be rebuilt mid-load. Drop back to thumbnails first.
    _pageKey.currentState?.releaseThreeD();
    await ref.read(repPreviewProvider(widget.catalogId).notifier).refresh();
  }

  /// Opens [path] in the editor, then re-reads: whatever the admin changed
  /// there (or published) is what this page should now show.
  Future<void> _openEditor([String path = '']) async {
    if (_opening) return;
    _opening = true;
    try {
      await context.push('$_editorBase$path');
    } finally {
      _opening = false;
    }
    if (!mounted) return;
    await _refresh();
  }

  void _openDish(CatalogProduct product) =>
      _openEditor('/dishes/${product.id}');

  @override
  Widget build(BuildContext context) {
    final previewAsync = ref.watch(repPreviewProvider(widget.catalogId));
    final catalog = previewAsync.valueOrNull?.catalog;
    final title = catalog?.displayName ?? widget.initialTitle ?? 'Catalog';
    final publicUrl = catalog?.publicUrl;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (publicUrl != null && publicUrl.isNotEmpty)
            IconButton(
              key: const ValueKey('admin_catalog_open_live'),
              tooltip: 'Open the live page',
              icon: const Icon(Icons.open_in_new),
              onPressed: () =>
                  ref.read(catalogLinkActionsProvider).open(publicUrl),
            ),
          // Straight to the publish screen, where the admin's "Publish by
          // admin" / "Unpublish by admin" buttons are.
          if (catalog != null)
            IconButton(
              key: const ValueKey('admin_catalog_publish'),
              tooltip: 'Publish or unpublish',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: () => _openEditor('/publish'),
            ),
          // The banner is the primary door; this is the same door for anyone
          // who does not think to tap a picture.
          if (catalog != null)
            IconButton(
              key: const ValueKey('admin_catalog_edit'),
              tooltip: 'Edit this catalog',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _openEditor,
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.mirageRed,
          backgroundColor: AppColors.surface1,
          onRefresh: _refresh,
          child: previewAsync.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (error, _) => isDelegationGone(error)
                // Deleted (or never existed) since the grid was loaded. A retry
                // would fail identically, so the way out is back to the grid.
                ? CatalogMessage(
                    icon: Icons.storefront_outlined,
                    title: delegationGoneTitle(isAdmin: true),
                    body: delegationGoneBody(isAdmin: true),
                    actionLabel: 'Back to All catalogs',
                    onAction: () => context.canPop()
                        ? context.pop()
                        : context.go(AppRoutes.adminCatalogs),
                  )
                : CatalogMessage(
                    icon: Icons.visibility_off_outlined,
                    title: "We couldn't load this catalog",
                    body: error is CatalogFailure
                        ? CatalogFeedback.failureText(error)
                        : CatalogFeedback.textForCode(null),
                    actionLabel: 'Try again',
                    onAction: () =>
                        ref.invalidate(repPreviewProvider(widget.catalogId)),
                  ),
            data: (preview) => CatalogPreviewPage(
              key: _pageKey,
              preview: preview,
              noticeBody: kAdminCatalogPageNotice,
              onFix: _openDish,
              onHeaderTap: _openEditor,
            ),
          ),
        ),
      ),
    );
  }
}
