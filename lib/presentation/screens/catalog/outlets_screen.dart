// lib/presentation/screens/catalog/outlets_screen.dart
//
// Stage 16 — multi-branch restaurants:
//   • [OutletsScreen] — `/catalog/outlets`: every outlet (main first), tap to
//     switch; "Add branch"; "Publish all outlets".
//   • [BrandWideGate] — wraps the brand-wide screens (look, badges, languages,
//     AR style, QR style, My plate). On a branch they are set on the main
//     outlet, so the gate shows that instead of an editor.
//   • [BranchLinkCard] — in the dish editor on a branch: "Follows your main
//     outlet", which fields this outlet changed, and "Reset to main outlet".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../application/catalog/outlet_scope.dart';
import '../../../application/catalog/product_detail_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/outlets_repository.dart';
import '../../../domain/catalog/outlet.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';

class OutletsScreen extends ConsumerStatefulWidget {
  const OutletsScreen({super.key});

  @override
  ConsumerState<OutletsScreen> createState() => _OutletsScreenState();
}

class _OutletsScreenState extends ConsumerState<OutletsScreen> {
  bool _publishing = false;

  Future<void> _addBranch() async {
    final added = await showDialog<Outlet>(
      context: context,
      builder: (_) => const _AddBranchDialog(),
    );
    if (added == null || !mounted) return;
    switchOutlet(ref, added.id);
    CatalogFeedback.confirm(
      CatalogFeedback.of(context),
      '${added.label} added with your full menu. You are now editing it.',
    );
  }

  Future<void> _publishAll() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _publishing = true);
    try {
      final results = await ref.read(outletsRepositoryProvider).publishAll();
      ref.invalidate(outletsProvider);
      ref.invalidate(catalogProvider);
      final failed = results.where((r) => !r.ok).length;
      if (mounted) {
        CatalogFeedback.confirm(
          messenger,
          failed == 0
              ? 'Publishing ${results.length} outlets.'
              : 'Publishing ${results.length - failed} of ${results.length} outlets. '
                  'Open the others to see what they need.',
        );
      }
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'publish');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(outletsProvider);
    final selected = ref.watch(selectedOutletIdProvider);
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Outlets'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text(
                e is CatalogFailure ? e.message : 'Could not load your outlets.',
                style: muted,
              ),
            ),
            data: (outlets) {
              final currentId = selected ??
                  (outlets.isNotEmpty ? outlets.first.id : null);
              return ListView(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                children: [
                  Text(
                    'Each outlet has its own page, QR standees, stock and plan. The menu and '
                    'the look are set on your main outlet and copied to every branch — a '
                    'branch can still change its own prices and stock.',
                    style: muted,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  for (final o in outlets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        key: Key('outlet-${o.id}'),
                        onTap: () {
                          switchOutlet(ref, o.isMain ? null : o.id);
                          Navigator.of(context).maybePop();
                        },
                        child: Row(
                          children: [
                            Icon(
                              o.isMain ? Icons.storefront : Icons.store_mall_directory_outlined,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    o.label,
                                    style: text.titleSmall,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    [
                                      o.isMain ? 'Main outlet' : 'Branch',
                                      if (o.hasUnpublishedChanges) 'unpublished changes',
                                    ].join(' · '),
                                    style: muted,
                                  ),
                                ],
                              ),
                            ),
                            if (o.id == currentId)
                              const Icon(Icons.check_circle, color: AppColors.textSecondary),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    key: const Key('outlets-add'),
                    label: 'Add branch',
                    icon: Icons.add_business_outlined,
                    variant: AppButtonVariant.secondary,
                    onPressed: outlets.length >= 11 ? null : _addBranch,
                  ),
                  if (outlets.length > 1) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      key: const Key('outlets-publish-all'),
                      label: 'Publish all outlets',
                      icon: Icons.cloud_upload_outlined,
                      isLoading: _publishing,
                      onPressed: _publishing ? null : _publishAll,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AddBranchDialog extends ConsumerStatefulWidget {
  const _AddBranchDialog();

  @override
  ConsumerState<_AddBranchDialog> createState() => _AddBranchDialogState();
}

class _AddBranchDialogState extends ConsumerState<_AddBranchDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outlet = await ref.read(outletsRepositoryProvider).addBranch(
            outletName: _name.text,
            phone: _phone.text,
            address: _address.text,
          );
      if (mounted) Navigator.of(context).pop(outlet);
    } on CatalogFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a branch'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('branch-name'),
              controller: _name,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Branch name',
                hintText: 'e.g. Koregaon Park',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Branch phone (optional)'),
            ),
            TextField(
              controller: _address,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Address (optional)'),
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: AppColors.error)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('branch-save'),
          onPressed: _busy || _name.text.trim().length < 2 ? null : _save,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// On a branch, the brand-wide screens show where to change them instead.
class BrandWideGate extends ConsumerWidget {
  const BrandWideGate({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider).valueOrNull;
    if (catalog == null || !catalog.isBranch) return child;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 40, color: AppColors.textMuted),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Set on your main outlet',
                  style: text.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Your restaurant looks the same at every outlet. Change this on the main '
                  'outlet and it is copied to ${catalog.outlet?.outletName ?? 'this branch'}.',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  key: const Key('brand-wide-switch'),
                  label: 'Switch to main outlet',
                  onPressed: () => switchOutlet(ref, null),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The API's field names → what the editor calls them.
const _fieldLabels = {
  'price': 'price',
  'name': 'name',
  'description': 'description',
  'categoryId': 'section',
  'tags': 'tags',
  'featured': 'featured',
  'foodType': 'veg / non-veg',
  'badgeIds': 'badges',
  'dietary': 'diet labels',
  'allergens': 'allergens',
  'spiceLevel': 'spice level',
  'i18n': 'translations',
  'assets.imageKey': 'photo',
  'pairsWith': 'pairings',
  'position': 'order',
};

/// "Follows your main outlet" + overrides + "Reset to main outlet".
class BranchLinkCard extends ConsumerStatefulWidget {
  const BranchLinkCard({super.key, required this.productId, required this.link});

  final String productId;
  final BranchLink link;

  @override
  ConsumerState<BranchLinkCard> createState() => _BranchLinkCardState();
}

class _BranchLinkCardState extends ConsumerState<BranchLinkCard> {
  bool _busy = false;

  Future<void> _reset() async {
    final outletId = ref.read(selectedOutletIdProvider);
    if (outletId == null) return;
    final messenger = CatalogFeedback.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(outletsRepositoryProvider)
          .resetProduct(outletId: outletId, productId: widget.productId);
      ref.invalidate(productDetailProvider(widget.productId));
      if (mounted) CatalogFeedback.confirm(messenger, 'Back to the main outlet\'s dish.');
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'product');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final own = widget.link.overriddenFields
        .map((f) => _fieldLabels[f] ?? f)
        .toSet()
        .toList();
    return AppCard(
      key: const Key('branch-link-card'),
      child: Row(
        children: [
          const Icon(Icons.link, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('From main outlet', style: text.titleSmall),
                Text(
                  own.isEmpty
                      ? 'Changes on the main outlet appear here automatically.'
                      : 'This outlet set its own ${own.join(', ')}; the rest follows the main outlet.',
                  style: muted,
                ),
              ],
            ),
          ),
          if (own.isNotEmpty)
            TextButton(
              key: const Key('branch-reset'),
              onPressed: _busy ? null : _reset,
              child: const Text('Reset'),
            ),
        ],
      ),
    );
  }
}
