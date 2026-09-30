// lib/presentation/widgets/catalog/ai_editor_actions.dart
//
// The product editor's AI helpers (more-customization Stage 13):
//   • [AiDescriptionButton] — "✨ Write description": three suggestions, the
//     picked one only FILLS the field; the owner still saves.
//   • [AiEnhancePhotoButton] — a brighter, 4:3 copy of the photo shown beside
//     the original; "Use enhanced" commits it, the original stays in history.
// Both render nothing unless AI is configured (`GET /catalog/ai/status`).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/product_detail_notifier.dart';
import '../../../data/repositories/ai_repository.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import 'catalog_feedback.dart';

class AiDescriptionButton extends ConsumerStatefulWidget {
  const AiDescriptionButton({
    super.key,
    required this.productId,
    required this.onPicked,
    this.enabled = true,
    this.repCatalogId,
  });

  final String productId;
  final ValueChanged<String> onPicked;
  final bool enabled;
  final String? repCatalogId;

  @override
  ConsumerState<AiDescriptionButton> createState() => _AiDescriptionButtonState();
}

class _AiDescriptionButtonState extends ConsumerState<AiDescriptionButton> {
  bool _loading = false;

  Future<void> _suggest() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _loading = true);
    try {
      final suggestions =
          await ref.read(aiRepositoryProvider(widget.repCatalogId)).describe([widget.productId]);
      final options = suggestions.isEmpty ? const <String>[] : suggestions.first.options;
      if (!mounted) return;
      if (options.isEmpty) {
        CatalogFeedback.confirm(messenger, 'No suggestion this time. Please try again.');
        return;
      }
      final picked = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text('Pick one — you can edit it after', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              for (final o in options)
                Card(
                  child: ListTile(
                    title: Text(o),
                    onTap: () => Navigator.pop(ctx, o),
                  ),
                ),
            ],
          ),
        ),
      );
      if (picked != null) widget.onPicked(picked);
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'description');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(aiStatusProvider(widget.repCatalogId)).valueOrNull;
    if (status == null || !status.enabled) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('ai-write-description'),
        icon: _loading
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_awesome, size: 18),
        label: const Text('Write description'),
        onPressed: !widget.enabled || _loading || !status.budgetLeft ? null : _suggest,
      ),
    );
  }
}

class AiEnhancePhotoButton extends ConsumerStatefulWidget {
  const AiEnhancePhotoButton({super.key, required this.product, this.enabled = true});

  final CatalogProduct product;
  final bool enabled;

  @override
  ConsumerState<AiEnhancePhotoButton> createState() => _AiEnhancePhotoButtonState();
}

class _AiEnhancePhotoButtonState extends ConsumerState<AiEnhancePhotoButton> {
  bool _loading = false;

  Future<void> _enhance() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _loading = true);
    try {
      final (key, url) = await ref.read(aiRepositoryProvider(null)).enhance(widget.product.id);
      if (!mounted) return;
      final use = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Enhanced photo'),
          content: SizedBox(
            width: 520,
            child: Row(
              children: [
                for (final (label, src) in [('Original', widget.product.thumbnailUrl ?? ''), ('Enhanced', url)])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        children: [
                          AspectRatio(
                            aspectRatio: 4 / 3,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(src, fit: BoxFit.cover),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(label, style: Theme.of(ctx).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep original')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Use enhanced')),
          ],
        ),
      );
      if (use != true || !mounted) return;
      await ref.read(productDetailProvider(widget.product.id).notifier).useStagedImage(key);
      if (mounted) CatalogFeedback.confirm(messenger, 'Enhanced photo saved. It shows after your next publish.');
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'photo');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(aiStatusProvider(null)).valueOrNull;
    if (status == null || !status.enabled) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: TextButton.icon(
        key: const Key('ai-enhance-photo'),
        icon: _loading
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_fix_high, size: 18, color: AppColors.royalGold),
        label: const Text('Enhance photo'),
        onPressed: !widget.enabled || _loading ? null : _enhance,
      ),
    );
  }
}
