// lib/presentation/screens/capture/review_grid_screen.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/review_flow_events.dart';
import '../../../application/capture/grid_selection.dart';
import '../../../domain/entities/capture_evaluation.dart';
import '../../../domain/entities/retake_request.dart';
import '../../../domain/entities/review_item.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/verdict_badge.dart';

/// Screen 7A — Level A Review grid. Shows every captured photo for the session as
/// a responsive, lazy thumbnail grid, each tile badged with its quality verdict
/// (Accepted / Warned / Rejected) so the user can see at a glance which shots are
/// good and which need attention.
///
/// Display + intent: it renders the supplied [items] (in the order given — it does
/// not sort) and emits [onTapTile]. It does NOT compute verdicts, decode full-res
/// images, or mutate the capture set.
///
/// MULTI-SELECT: when [onDeleteSelected] is supplied, the grid gains platform-
/// idiomatic multi-select over ONE shared, id-keyed [GridSelection] — an Android
/// Contextual Action Bar (long-press to enter, count + actions, BACK/X exits) and
/// an iOS Edit mode (a "Select" nav button, checkmarks, Cancel/Done, a bottom
/// action toolbar). The selection mechanism + chrome live here; the action effect
/// (deleting the photos) is the parent's callback. The platform branch is read
/// from `Theme.of(context).platform` (overridable in tests), mirroring the
/// checklist tip-sheet pattern — never `Platform.isIOS`.
///
/// Reusable from both the completion screen's "Review" CTA and a project's
/// resume/view-later entry — both pass a `List<ReviewItem>`.
class ReviewGridScreen extends StatefulWidget {
  const ReviewGridScreen({
    super.key,
    required this.items,
    this.onTapTile,
    this.onDeleteSelected,
    this.onRetake,
    this.onRetakeSelected,
    this.onBackToCapture,
    this.onConfirm,
    this.confirmLabel = 'Proceed',
    this.reviewAnalytics,
    this.analyticsLevel,
    this.title = 'Review — Level A',
  });

  /// The captures to review, in display order (capture time or ring index — the
  /// parent decides; this screen does not reorder).
  final List<ReviewItem> items;

  /// Tap intent for a future preview/detail (normal mode only). No preview here.
  final void Function(ReviewItem)? onTapTile;

  /// Multi-select delete hook. Supplying it ENABLES multi-select; the parent
  /// performs the actual delete (and rebuilds with fewer [items]). Null disables
  /// multi-select entirely (the grid stays a plain display + tap surface).
  final void Function(Set<String> ids)? onDeleteSelected;

  /// Retake intent hook. Supplying it shows a per-tile Retake control (outside
  /// selection mode, on tiles whose [ReviewItem.ringIndex] is known) that builds
  /// a [RetakeRequest] for that segment and hands it to the parent — which OWNS
  /// the navigation into the Level A capture screen (the grid stays display +
  /// intent). Null hides the control. The grid debounces rapid taps to a single
  /// emission so only one retake navigation fires.
  final void Function(RetakeRequest request)? onRetake;

  /// Multi-select Retake hook — the batch counterpart to [onRetake]. Supplying it
  /// adds a Retake action to the selection action surface (Android CAB / iOS Edit
  /// toolbar), acting on the whole selection: the parent removes those photos and
  /// navigates back to capture targeting a freed segment (see
  /// `ReviewActionsController.retakeSelected`). The grid only emits the intent.
  final void Function(Set<String> ids)? onRetakeSelected;

  /// "Back to Capture" hook. Supplying it shows a persistent bottom bar (outside
  /// selection mode) to resume the guided flow with the current coverage. Always
  /// available (not selection-gated); the parent performs the navigation.
  final void Function()? onBackToCapture;

  /// Primary "confirm this level + advance" hook. Supplying it makes this the
  /// in-flow review screen (Screen 7A/7B/7C): the bottom bar gains a primary CTA
  /// (and keeps Back-to-Capture when also supplied). The grid guards against a
  /// rapid double-tap so the parent's forward navigation fires at most once.
  final void Function()? onConfirm;

  /// Label for the [onConfirm] primary CTA (level config supplies the wording).
  final String confirmLabel;

  /// Funnel-analytics context for `photo_review_opened`. Supplied by the screen
  /// owner (which knows project/session/coverage — the reusable grid does not).
  /// When non-null the grid emits one `photo_review_opened` per OPEN (in
  /// `initState`, so a rebuild/rotation never re-fires). Null → the funnel event
  /// is skipped (the display-only `review_grid_viewed` still fires).
  final ReviewOpenAnalytics? reviewAnalytics;

  /// The capture level (A/B/C) this review belongs to, included in the
  /// `review_grid_viewed` payload so the flow review (Eye/Top/Bottom Ring) is
  /// funnel-attributed. The reusable display grid (resume/view-later) omits it.
  final String? analyticsLevel;

  /// App-bar title.
  final String title;

  @override
  State<ReviewGridScreen> createState() => _ReviewGridScreenState();
}

class _ReviewGridScreenState extends State<ReviewGridScreen> {
  final GridSelection _selection = GridSelection();

  /// Last accepted retake tap — used to debounce rapid double-taps so only ONE
  /// retake navigation fires (the parent's `onRetake` typically navigates away,
  /// but the grid stays mounted underneath until the route transition runs).
  DateTime? _lastRetakeAt;
  static const Duration _retakeDebounce = Duration(milliseconds: 800);

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  bool get _selectionEnabled => widget.onDeleteSelected != null;

  bool _isCupertino(BuildContext context) {
    final p = Theme.of(context).platform;
    return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    final c = _Counts.of(widget.items);
    Analytics.logEvent(AnalyticsEvents.reviewGridViewed, {
      if (widget.analyticsLevel != null) 'level': widget.analyticsLevel,
      'total': widget.items.length,
      'accepted': c.accepted,
      'warned': c.warned,
      'rejected': c.rejected,
      'device_type': _deviceType,
    });
    // Review-session funnel: once per OPEN (initState — never on rebuild/rotate),
    // even with zero photos. Only when the owner supplied funnel context.
    widget.reviewAnalytics?.opened(widget.items.length, deviceType: _deviceType);
  }

  @override
  void didUpdateWidget(ReviewGridScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Item set changed (e.g. a delete removed photos) → drop gone ids from the
    // selection so it never references removed items; auto-exit per platform.
    if (!identical(oldWidget.items, widget.items)) {
      final present = {for (final i in widget.items) i.captureId};
      _selection.retain(present, autoExitWhenEmpty: !_isCupertino(context));
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  void _onOpen(ReviewItem item) {
    final cb = widget.onTapTile;
    if (cb == null) return;
    Analytics.logEvent(AnalyticsEvents.reviewTileTapped, {
      'capture_id': item.captureId,
      'verdict': item.verdict.name,
    });
    cb(item);
  }

  void _handleTap(ReviewItem item) {
    if (_selection.isSelectionMode) {
      _selection.toggle(item.captureId,
          autoExitWhenEmpty: !_isCupertino(context));
    } else {
      _onOpen(item);
    }
  }

  void _handleLongPress(ReviewItem item) {
    // Android entry gesture. iOS enters via the Select button instead.
    if (!_selectionEnabled || _isCupertino(context)) return;
    _selection.enterSelection(item.captureId);
  }

  void _selectAll() =>
      _selection.selectAll([for (final i in widget.items) i.captureId]);

  void _deleteSelected() {
    final ids = _selection.selectedIds;
    if (ids.isEmpty) return;
    widget.onDeleteSelected?.call(ids);
    // Delete is terminal on both platforms → leave selection mode.
    _selection.exitSelection();
  }

  /// Multi-select Retake: hand the selection to the parent (which removes them +
  /// navigates to capture). Leaves selection mode like Delete — the parent
  /// navigates away, so the selection chrome must not linger.
  void _retakeSelected() {
    final ids = _selection.selectedIds;
    if (ids.isEmpty) return;
    widget.onRetakeSelected?.call(ids);
    _selection.exitSelection();
  }

  /// Back to Capture: exit any selection first (per the multi-select contract),
  /// then let the parent navigate.
  void _backToCapture() {
    if (_selection.isSelectionMode) _selection.exitSelection();
    widget.onBackToCapture?.call();
  }

  /// True once [_confirm] has fired — guards the primary CTA against a rapid
  /// double-tap so the parent's forward navigation runs at most once.
  bool _confirmed = false;

  /// Confirm this level and advance. Single-shot: a second tap (before the route
  /// transition completes) is swallowed.
  void _confirm() {
    if (_confirmed) return;
    _confirmed = true;
    widget.onConfirm?.call();
  }

  /// Builds a [RetakeRequest] for [item]'s segment and hands it to the parent,
  /// debounced to a single emission. A tile without a known [ReviewItem.ringIndex]
  /// can't target a segment, so it has no retake control and this is a no-op.
  void _requestRetake(ReviewItem item) {
    final cb = widget.onRetake;
    final ringIndex = item.ringIndex;
    if (cb == null || ringIndex == null) return;

    final now = DateTime.now();
    if (_lastRetakeAt != null && now.difference(_lastRetakeAt!) < _retakeDebounce) {
      return; // swallow the rapid second tap — one navigation only
    }
    _lastRetakeAt = now;

    cb(RetakeRequest(
      ringIndex: ringIndex,
      // An existing tile replaces its capture; a (future) missing-segment
      // placeholder would carry no real captureId and fill instead.
      replacingCaptureId: item.captureId,
      returnToReviewAfter: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final isCupertino = _isCupertino(context);

    return ListenableBuilder(
      listenable: _selection,
      builder: (context, _) {
        final selectionMode = _selection.isSelectionMode;
        return PopScope(
          // Always intercepted. While selecting, BACK exits selection — not the
          // screen; otherwise it goes through the shared flow-back helper (the
          // review route is go()-navigated, so a successful pop of the
          // single-page stack would exit the app).
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (selectionMode) {
              _selection.exitSelection();
            } else {
              navigateBack(context);
            }
          },
          child: Scaffold(
            backgroundColor: AppColors.bgPrimary,
            appBar: _buildAppBar(context, isCupertino, selectionMode),
            // While selecting on iOS the bottom bar IS the Edit-mode action
            // toolbar; otherwise it's the persistent Back-to-Capture bar (when a
            // hook is supplied). The two never coexist, so there is one coherent
            // action surface at a time, never two competing ones.
            bottomNavigationBar: (selectionMode && isCupertino)
                ? _buildIosToolbar(context)
                : selectionMode
                    ? null
                    // In-flow review: a primary confirm CTA (+ Back-to-Capture).
                    : widget.onConfirm != null
                        ? _buildFlowBar(context)
                        // Reusable display grid: just the Back-to-Capture bar.
                        : widget.onBackToCapture != null
                            ? _buildBackToCaptureBar(context)
                            : null,
            body: SafeArea(
              top: false,
              child: items.isEmpty
                  ? const _EmptyState()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SummaryHeader(counts: _Counts.of(items)),
                        Expanded(
                          child: _Grid(
                            items: items,
                            selectionMode: selectionMode,
                            isSelected: _selection.isSelected,
                            onTapItem: _handleTap,
                            onLongPressItem:
                                (_selectionEnabled && !isCupertino)
                                    ? _handleLongPress
                                    : null,
                            // Retake control is hidden during selection (the tile
                            // is busy being (de)selected) and when no hook is set.
                            onRetakeItem:
                                (widget.onRetake != null && !selectionMode)
                                    ? _requestRetake
                                    : null,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  // ── App bars ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(
      BuildContext context, bool isCupertino, bool selectionMode) {
    if (selectionMode) {
      return isCupertino ? _iosSelectionBar() : _androidCab();
    }
    return AppBar(
      backgroundColor: AppColors.bgPrimary,
      title: Text(widget.title),
      elevation: 0,
      actions: [
        if (_selectionEnabled && isCupertino)
          TextButton(
            key: const Key('review_select_button'),
            onPressed: () => _selection.enterSelection(),
            child: const Text('Select'),
          ),
      ],
    );
  }

  /// Android Contextual Action Bar: close (X) + count + select-all + delete.
  PreferredSizeWidget _androidCab() {
    final count = _selection.count;
    return AppBar(
      backgroundColor: AppColors.surface1,
      elevation: 0,
      leading: IconButton(
        key: const Key('review_cab_close'),
        tooltip: 'Close selection',
        icon: const Icon(Icons.close),
        onPressed: _selection.exitSelection,
      ),
      title: Text('$count', key: const Key('review_cab_count')),
      actions: [
        IconButton(
          key: const Key('review_action_select_all'),
          tooltip: 'Select all',
          icon: const Icon(Icons.select_all),
          onPressed: _selectAll,
        ),
        if (widget.onRetakeSelected != null)
          IconButton(
            key: const Key('review_action_retake'),
            tooltip: 'Retake',
            icon: const Icon(Icons.refresh),
            onPressed: count == 0 ? null : _retakeSelected,
          ),
        IconButton(
          key: const Key('review_action_delete'),
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: count == 0 ? null : _deleteSelected,
        ),
      ],
    );
  }

  /// iOS Edit-mode nav bar: Cancel + count + Done. Actions live in the bottom
  /// toolbar ([_buildIosToolbar]).
  PreferredSizeWidget _iosSelectionBar() {
    return AppBar(
      backgroundColor: AppColors.surface1,
      elevation: 0,
      automaticallyImplyLeading: false,
      leadingWidth: 96,
      leading: TextButton(
        key: const Key('review_ios_cancel'),
        // Cancel reverts: our selection has no deferred effect (actions apply
        // immediately), so reverting == clearing + exiting.
        onPressed: _selection.exitSelection,
        child: const Text('Cancel'),
      ),
      title: Text('${_selection.count} Selected'),
      actions: [
        TextButton(
          key: const Key('review_ios_done'),
          onPressed: _selection.exitSelection,
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildIosToolbar(BuildContext context) {
    final count = _selection.count;
    return BottomAppBar(
      color: AppColors.surface1,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            key: const Key('review_action_select_all'),
            onPressed: _selectAll,
            child: const Text('Select All'),
          ),
          if (widget.onRetakeSelected != null)
            TextButton(
              key: const Key('review_action_retake'),
              onPressed: count == 0 ? null : _retakeSelected,
              child: Text(
                'Retake',
                style: TextStyle(
                  color: count == 0 ? AppColors.disabled : AppColors.royalGold,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          TextButton(
            key: const Key('review_action_delete'),
            onPressed: count == 0 ? null : _deleteSelected,
            child: Text(
              'Delete',
              style: TextStyle(
                color: count == 0 ? AppColors.disabled : AppColors.mirageRed,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// In-flow review bottom bar (Screen 7A/7B/7C): a secondary "Back to Capture"
  /// (when supplied) above a primary confirm CTA that advances the flow. Shown
  /// when [ReviewGridScreen.onConfirm] is supplied (outside selection mode).
  Widget _buildFlowBar(BuildContext context) {
    // A content-sized bar (NOT BottomAppBar, whose fixed height clips a two-button
    // column). SafeArea keeps the CTAs clear of the gesture inset.
    return Material(
      color: AppColors.surface1,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onBackToCapture != null) ...[
                AppButton.secondary(
                  key: const Key('review_back_to_capture'),
                  label: 'Back to Capture',
                  onPressed: _backToCapture,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              AppButton(
                key: const Key('review_confirm'),
                label: widget.confirmLabel,
                onPressed: _confirm,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Persistent "Back to Capture" bar (outside selection mode) — always available
  /// to resume the guided flow with the current coverage. Shown only when an
  /// [ReviewGridScreen.onBackToCapture] hook is supplied.
  Widget _buildBackToCaptureBar(BuildContext context) {
    return BottomAppBar(
      color: AppColors.surface1,
      child: SizedBox(
        width: double.infinity,
        child: TextButton.icon(
          key: const Key('review_back_to_capture'),
          onPressed: _backToCapture,
          icon: const Icon(Icons.camera_alt_outlined,
              color: AppColors.textPrimary),
          label: Text(
            'Back to Capture',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Verdict tallies for the header summary + analytics.
class _Counts {
  const _Counts({
    required this.accepted,
    required this.warned,
    required this.rejected,
  });

  final int accepted;
  final int warned;
  final int rejected;

  factory _Counts.of(List<ReviewItem> items) {
    var a = 0, w = 0, r = 0;
    for (final i in items) {
      switch (i.verdict) {
        case CaptureVerdict.accepted:
          a++;
        case CaptureVerdict.warn:
          w++;
        case CaptureVerdict.reject:
          r++;
      }
    }
    return _Counts(accepted: a, warned: w, rejected: r);
  }
}

/// A compact row of verdict tallies (✓ / ! / ✗), reusing the badge colour/icon
/// tokens so the summary speaks the same visual language as the tiles.
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.counts});

  final _Counts counts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          _SummaryChip(verdict: CaptureVerdict.accepted, count: counts.accepted),
          const SizedBox(width: AppSpacing.md),
          _SummaryChip(verdict: CaptureVerdict.warn, count: counts.warned),
          const SizedBox(width: AppSpacing.md),
          _SummaryChip(verdict: CaptureVerdict.reject, count: counts.rejected),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.verdict, required this.count});

  final CaptureVerdict verdict;
  final int count;

  @override
  Widget build(BuildContext context) {
    final color = VerdictBadge.colorFor(verdict);
    return Semantics(
      label: '${VerdictBadge.labelFor(verdict)}: $count',
      excludeSemantics: true, // collapse the inner Icon/Text into one a11y node
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(VerdictBadge.iconFor(verdict), color: color, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '$count',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

/// The lazy, responsive thumbnail grid. Column count adapts to width; tiles are
/// square and downscale-decoded.
class _Grid extends StatelessWidget {
  const _Grid({
    required this.items,
    required this.selectionMode,
    required this.isSelected,
    required this.onTapItem,
    required this.onLongPressItem,
    required this.onRetakeItem,
  });

  final List<ReviewItem> items;
  final bool selectionMode;
  final bool Function(String id) isSelected;
  final void Function(ReviewItem) onTapItem;
  final void Function(ReviewItem)? onLongPressItem;
  final void Function(ReviewItem)? onRetakeItem;

  /// Target tile edge (logical px); column count is derived so tiles stay legible
  /// — ~3 columns on a phone, more on tablets.
  static const double _targetTile = 120;
  static const double _spacing = AppSpacing.sm;
  static const double _pad = AppSpacing.lg;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - _pad * 2;
        final crossAxisCount = (available / _targetTile).floor().clamp(2, 8);
        // The exact tile width for this column count — used to size the decode.
        final tileWidth =
            (available - (crossAxisCount - 1) * _spacing) / crossAxisCount;

        return GridView.builder(
          key: const PageStorageKey<String>('review_grid'),
          padding: const EdgeInsets.all(_pad),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: _spacing,
            mainAxisSpacing: _spacing,
            childAspectRatio: 1, // square tiles
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _ReviewTile(
              // Key by capture id → correct reuse as the list shifts; a
              // re-captured id updates rather than duplicating.
              key: ValueKey<String>(item.captureId),
              item: item,
              tileWidth: tileWidth,
              selectionMode: selectionMode,
              selected: isSelected(item.captureId),
              onTap: () => onTapItem(item),
              onLongPress: onLongPressItem == null
                  ? null
                  : () => onLongPressItem!(item),
              // Only tiles with a known ring position can be retaken (the request
              // targets a segment). Missing ringIndex → no control.
              onRetake: (onRetakeItem == null || item.ringIndex == null)
                  ? null
                  : () => onRetakeItem!(item),
            );
          },
        );
      },
    );
  }
}

/// One grid tile: a downscale-decoded thumbnail + a corner [VerdictBadge] + an
/// optional ring-index label. In selection mode it also shows a selection control
/// (a check / outline circle) and a selected border. Missing/corrupt files fall
/// back to a neutral tile (still badged); loading shows a neutral surface.
class _ReviewTile extends StatelessWidget {
  const _ReviewTile({
    super.key,
    required this.item,
    required this.tileWidth,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onRetake,
  });

  final ReviewItem item;
  final double tileWidth;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetake;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Decode at the tile's pixel width (preserve aspect via width-only) so a
    // full-res photo never decodes into memory for a small tile — the key
    // perf/memory guard for large sets on low-end devices.
    final cachePx = (tileWidth * dpr).round();

    final image = Image.file(
      File(item.filePath),
      fit: BoxFit.cover,
      cacheWidth: cachePx,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSync) =>
          frame == null ? const _TileSurface() : child,
      errorBuilder: (context, _, __) => const _TileSurface(
        child: Icon(Icons.broken_image_outlined,
            size: 24, color: AppColors.textMuted),
      ),
    );

    final radius = BorderRadius.circular(AppRadius.xs);

    return Semantics(
      button: true,
      selected: selectionMode ? selected : null,
      label: _semanticLabel(item, selectionMode, selected),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: selected
                  ? Border.all(color: AppColors.royalGold, width: 3)
                  : null,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: image),
                  // Dim selected tiles a touch so the highlight reads.
                  if (selected)
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0x33C9A24D)),
                    ),
                  // Verdict badge — top-right corner.
                  Positioned(
                    top: AppSpacing.xs,
                    right: AppSpacing.xs,
                    child: VerdictBadge(verdict: item.verdict),
                  ),
                  // Selection control — top-left, only in selection mode.
                  if (selectionMode)
                    Positioned(
                      top: AppSpacing.xs,
                      left: AppSpacing.xs,
                      child: _SelectionCheck(selected: selected),
                    ),
                  // Optional ring-index label — bottom-left.
                  if (item.ringIndex != null)
                    Positioned(
                      left: AppSpacing.xs,
                      bottom: AppSpacing.xs,
                      child: _RingIndexLabel(index: item.ringIndex!),
                    ),
                  // Retake control — bottom-right (outside selection mode only).
                  if (onRetake != null && !selectionMode)
                    Positioned(
                      right: AppSpacing.xs,
                      bottom: AppSpacing.xs,
                      child: _RetakeButton(
                        captureId: item.captureId,
                        ringIndex: item.ringIndex,
                        onTap: onRetake!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _semanticLabel(ReviewItem item, bool selectionMode, bool sel) {
    final verdict = VerdictBadge.labelFor(item.verdict);
    final base = item.ringIndex != null
        ? 'Capture, position ${item.ringIndex! + 1}, $verdict'
        : 'Capture, $verdict';
    if (!selectionMode) return base;
    return '$base, ${sel ? 'Selected' : 'Not selected'}';
  }
}

/// The per-tile selection indicator: a filled gold check when selected, a hollow
/// outline circle when not (shown only in selection mode).
class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected
            ? AppColors.royalGold
            : AppColors.bgPrimary.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? AppColors.royalGold : AppColors.textPrimary,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 15, color: AppColors.bgPrimary)
          : null,
    );
  }
}

/// Neutral placeholder/fallback surface filling a tile.
class _TileSurface extends StatelessWidget {
  const _TileSurface({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: AppColors.surface2, child: Center(child: child));
}

/// Small ring-position chip overlaid on a tile.
class _RingIndexLabel extends StatelessWidget {
  const _RingIndexLabel({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgPrimary.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        // 1-based for display.
        '${index + 1}',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// Small circular Retake affordance overlaid on a tile (bottom-right). Tapping
/// it asks the parent to re-shoot this tile's ring position. Its own tap handler
/// wins the gesture arena inside the tile, so it never doubles as a tile open.
class _RetakeButton extends StatelessWidget {
  const _RetakeButton({
    required this.captureId,
    required this.ringIndex,
    required this.onTap,
  });

  final String captureId;
  final int? ringIndex;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: ringIndex != null
          ? 'Retake position ${ringIndex! + 1}'
          : 'Retake',
      child: GestureDetector(
        key: Key('review_retake_$captureId'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: AppColors.bgPrimary.withValues(alpha: 0.72),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.royalGold, width: 1.5),
          ),
          child: const Icon(Icons.refresh, size: 16, color: AppColors.royalGold),
        ),
      ),
    );
  }
}

/// Shown when there are no captures (defensive — Review is normally reached with
/// captures).
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 56, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No captures yet',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
