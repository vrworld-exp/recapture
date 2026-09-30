// lib/presentation/widgets/catalog/product_offers_line.dart
//
// The product editor's "On offer: Happy hour (−20%)" (more-customization
// Stage 10). Shows every switched-on offer that touches this dish; when
// several are live at once, the one customers actually get is marked. Renders
// nothing when the dish is on no offer (or the read fails — it is a courtesy
// line, never an error in the editor).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/offers_repository.dart';
import '../../../domain/catalog/offer.dart';

class ProductOffersLine extends ConsumerWidget {
  const ProductOffersLine({super.key, required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(productOffersProvider(productId)).valueOrNull ?? const [];
    if (offers.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: InkWell(
        key: const Key('product-offers-line'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.push(AppRoutes.catalogOffers),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.local_offer_outlined, size: 16, color: AppColors.royalGold),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                'On offer: ${offers.map((o) => _describe(o, offers.length > 1)).join(' · ')}',
                style: text.bodySmall?.copyWith(color: AppColors.royalGold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _describe(ProductOffer o, bool several) {
    final status = o.status == OfferStatus.live ? (several && o.wins ? ', live — applies' : ', live') : '';
    final price = o.finalPrice == null ? ' — no discount on this price' : '';
    return '${o.label}$status$price';
  }
}
