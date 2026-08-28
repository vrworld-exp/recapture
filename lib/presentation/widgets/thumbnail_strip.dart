// lib/presentation/widgets/thumbnail_strip.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/capture_thumbnail.dart';

/// Level A thumbnail strip: a compact row of the most recent captures
/// (newest-first, capped at [maxVisible]) for quick visual confirmation that
/// captures are landing. Display-only — it renders the supplied [recent] slice
/// and emits an optional [onTapThumbnail]; it does NOT capture, save, or own the
/// photo set, and builds no preview.
///
/// Each tile downscale-decodes its image (`cacheWidth` matched to the tile's
/// pixel size) so full-res photos never decode into memory for tiny tiles — the
/// key low-end-device guard. A new capture animates in (a fresh keyed tile fades
/// + slides); the row resizes via [AnimatedSize] as the oldest drops off.
/// Reduce-motion makes inserts/removes instant.
class ThumbnailStrip extends StatelessWidget {
  const ThumbnailStrip({
    super.key,
    required this.recent,
    this.maxVisible = 5,
    this.onTapThumbnail,
    this.tileSize = 46,
  });

  /// Recent captures (any order — the strip sorts newest-first by `capturedAt`).
  final List<CaptureThumbnail> recent;

  /// Max tiles shown (3–5). Newest [maxVisible] are kept.
  final int maxVisible;

  /// Optional tap callback (parent may open a preview — none is built here).
  final void Function(CaptureThumbnail)? onTapThumbnail;

  /// Tile edge length in logical pixels.
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    // Newest-first, capped. (Copy before sorting — never mutate the input.)
    final visible = ([...recent]
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt)))
        .take(maxVisible.clamp(0, 999))
        .toList();

    return AnimatedSize(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in visible)
            Padding(
              // Key by id so tiles reuse correctly as items shift, and a new id
              // is a fresh subtree → its entry animation plays.
              key: ValueKey<String>(t.id),
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: _ThumbTile(
                thumbnail: t,
                size: tileSize,
                onTap: onTapThumbnail == null ? null : () => onTapThumbnail!(t),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThumbTile extends StatefulWidget {
  const _ThumbTile({
    required this.thumbnail,
    required this.size,
    this.onTap,
  });

  final CaptureThumbnail thumbnail;
  final double size;
  final VoidCallback? onTap;

  @override
  State<_ThumbTile> createState() => _ThumbTileState();
}

class _ThumbTileState extends State<_ThumbTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;
  bool _entryStarted = false;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entryStarted) return;
    _entryStarted = true;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _entry.value = 1; // instant
    } else {
      _entry.forward();
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Decode at the tile's pixel size (preserve aspect via width-only), so a
    // full-res photo is never decoded for a tiny tile.
    final cachePx = (widget.size * dpr).round();

    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Image.file(
          File(widget.thumbnail.filePath),
          fit: BoxFit.cover,
          cacheWidth: cachePx,
          gaplessPlayback: true,
          // Neutral placeholder while decoding.
          frameBuilder: (context, child, frame, wasSync) =>
              frame == null ? _surface() : child,
          // Graceful fallback for a missing / corrupt file — never a red error box.
          errorBuilder: (context, _, __) => _surface(
            child: const Icon(
              Icons.broken_image_outlined,
              size: 18,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
    );

    final bordered = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: AppColors.royalGold.withValues(alpha: 0.7),
        ),
        boxShadow: const [
          BoxShadow(color: AppColors.scrim, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: tile,
    );

    final tappable = widget.onTap == null
        ? bordered
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: bordered,
          );

    // Entry: fade + a small slide-in from the leading edge.
    return FadeTransition(
      opacity: _entry,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-0.25, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOut)),
        child: tappable,
      ),
    );
  }

  Widget _surface({Widget? child}) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: ColoredBox(
          color: AppColors.surface2,
          child: Center(child: child),
        ),
      );
}
