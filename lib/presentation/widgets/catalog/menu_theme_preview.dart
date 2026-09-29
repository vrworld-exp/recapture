// lib/presentation/widgets/catalog/menu_theme_preview.dart
//
// A phone-frame approximation of the public Mirage menu in a given palette
// (more-customization Stage 2). NOT a WebView and not pixel-exact: it paints
// the surfaces Mirage-fe themes — header, search, category tabs, dish cards,
// the AR button, the Featured badge, the floating Menu pill — in the SAME
// resolved colours ([resolveMenuColors]), so an owner judges the look before
// publishing it.
//
// Text over a dish photo stays light in every palette, because Mirage-fe keeps
// it light over its dark photo scrim ("on-media" in tailwind.config.js).
import 'package:flutter/material.dart';

import '../../../domain/catalog/appearance.dart';
import '../../../domain/catalog/menu_theme_presets.dart';

/// `#RRGGBB` → an opaque [Color].
Color menuColor(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

/// Mirage-fe's fixed on-media text colour.
const Color _onMedia = Color(0xFFF5F5F7);

/// One dish the preview draws. Real dishes when the catalog has them.
class PreviewDish {
  const PreviewDish({required this.name, this.price, this.imageUrl, this.featured = false});

  final String name;
  final String? price;
  final String? imageUrl;
  final bool featured;
}

class MenuThemePreview extends StatelessWidget {
  const MenuThemePreview({
    super.key,
    required this.colors,
    required this.restaurantName,
    this.logoUrl,
    this.dishes = const [],
    this.width = 280,
    this.layout = MenuLayout.grid,
    this.coverUrl,
  });

  final MenuThemeColors colors;
  final String restaurantName;
  final String? logoUrl;
  final List<PreviewDish> dishes;
  final double width;

  /// Stage 3: how the dishes are drawn.
  final MenuLayout layout;

  /// Stage 3: the hero banner, when the catalog has a cover.
  final String? coverUrl;

  static const List<PreviewDish> placeholderDishes = [
    PreviewDish(name: 'Paneer Tikka', price: '₹249', featured: true),
    PreviewDish(name: 'Masala Dosa', price: '₹149'),
  ];

  @override
  Widget build(BuildContext context) {
    final bg = menuColor(colors.bg);
    final surface = menuColor(colors.surface);
    final text = menuColor(colors.text);
    final text2 = menuColor(colors.text2);
    final primary = menuColor(colors.primary);
    final shown = (dishes.isEmpty ? placeholderDishes : dishes).take(2).toList();

    return Semantics(
      label: 'Preview of your public menu',
      child: Container(
        width: width,
        height: width * 2,
        decoration: BoxDecoration(
          color: const Color(0xFF050507),
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: const Color(0xFF2A2A30), width: 2),
        ),
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: ColoredBox(
            color: bg,
            child: Stack(
              children: [
                ListView(
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                  children: [
                    if (coverUrl != null) ...[
                      _Cover(url: coverUrl!, bg: bg),
                      const SizedBox(height: 8),
                    ],
                    // Header: logo, name, contact + share in the primary colour.
                    Row(
                      children: [
                        _Logo(url: logoUrl, surface: surface),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            restaurantName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: text,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        _RoundIcon(icon: Icons.call, bg: surface, fg: primary),
                        const SizedBox(width: 6),
                        _RoundIcon(icon: Icons.share, bg: surface, fg: primary),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Search field.
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, size: 14, color: text2),
                          const SizedBox(width: 6),
                          Text('Search dishes...', style: TextStyle(color: text2, fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _Tabs(colors: colors),
                    const SizedBox(height: 10),
                    for (final dish in shown) ...[
                      if (layout == MenuLayout.list)
                        _DishRow(dish: dish, colors: colors)
                      else
                        _DishCard(
                          dish: dish,
                          colors: colors,
                          // `large` is the same card at 4:3 of the frame width.
                          height: layout == MenuLayout.large ? (width - 40) * 3 / 4 : 150,
                        ),
                      SizedBox(height: layout == MenuLayout.list ? 8 : 10),
                    ],
                  ],
                ),
                // The floating Menu pill, over the overlay scrim like Mirage-fe.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                      decoration: BoxDecoration(
                        color: menuColor(colors.overlay).withValues(alpha: 0.667),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: text.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.menu, size: 14, color: text),
                          const SizedBox(width: 6),
                          Text(
                            'Menu',
                            style: TextStyle(color: text, fontWeight: FontWeight.w700, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.url, required this.surface});

  final String? url;
  final Color surface;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: url == null
            ? const Icon(Icons.storefront, size: 16, color: Color(0xFF8A8A96))
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.storefront, size: 16, color: Color(0xFF8A8A96)),
              ),
      );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.bg, required this.fg});

  final IconData icon;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, size: 13, color: fg),
      );
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.colors});

  final MenuThemeColors colors;

  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: menuColor(colors.surface),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [menuColor(colors.ctaFrom), menuColor(colors.ctaTo)],
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  'Chef’s Special',
                  style: TextStyle(
                    color: menuColor(colors.onPrimary),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Text(
                  'All Menu',
                  style: TextStyle(
                    color: menuColor(colors.text2),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.bg});

  final String url;
  final Color bg;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              // Mirage-fe's `card-fade`: into the page colour at the bottom.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [bg.withValues(alpha: 0.9), bg.withValues(alpha: 0)],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

/// The `list` layout's compact row (mirage-fe MenuItemRow).
class _DishRow extends StatelessWidget {
  const _DishRow({required this.dish, required this.colors});

  final PreviewDish dish;
  final MenuThemeColors colors;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: menuColor(colors.surface),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: dish.imageUrl != null
                    ? Image.network(
                        dish.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => ColoredBox(color: menuColor(colors.surface2)),
                      )
                    : ColoredBox(
                        color: menuColor(colors.surface2),
                        child: Icon(
                          Icons.restaurant,
                          size: 18,
                          color: menuColor(colors.text2).withValues(alpha: 0.5),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    dish.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: menuColor(colors.text),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  if (dish.price != null)
                    Text(
                      dish.price!,
                      style: TextStyle(
                        color: menuColor(colors.primary),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [menuColor(colors.ctaFrom), menuColor(colors.ctaTo)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'AR',
                style: TextStyle(
                  color: menuColor(colors.onPrimary),
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
}

class _DishCard extends StatelessWidget {
  const _DishCard({required this.dish, required this.colors, this.height = 150});

  final PreviewDish dish;
  final MenuThemeColors colors;
  final double height;

  @override
  Widget build(BuildContext context) {
    final surface = menuColor(colors.surface);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: surface),
            if (dish.imageUrl != null)
              Image.network(
                dish.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              )
            else
              Center(
                child: Icon(
                  Icons.restaurant,
                  size: 40,
                  color: menuColor(colors.text2).withValues(alpha: 0.4),
                ),
              ),
            // Mirage-fe's cinematic scrim: black, whatever the palette.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xE6000000), Color(0x33000000), Color(0x00000000)],
                  stops: [0, 0.5, 1],
                ),
              ),
            ),
            if (dish.featured)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0x80000000),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: menuColor(colors.accent).withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    '★ FEATURED',
                    style: TextStyle(
                      color: menuColor(colors.accent),
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          dish.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _onMedia,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        if (dish.price != null)
                          Text(
                            dish.price!,
                            style: TextStyle(
                              color: _onMedia.withValues(alpha: 0.9),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [menuColor(colors.ctaFrom), menuColor(colors.ctaTo)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'AR VIEW',
                      style: TextStyle(
                        color: menuColor(colors.onPrimary),
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
