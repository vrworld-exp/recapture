// lib/presentation/screens/projects/image_prep_crop_editor.dart
//
// The interactive crop layer of the Prepare-Images screen, laid over the
// active image's preview:
//   • polygon mode — tap to drop outline points, tap the first point (or the
//     Close chip) to close, drag vertices to refine, long-press a segment to
//     insert a point, select + delete a point, undo the last. Outside the
//     closed polygon is dimmed live; Apply hands the CLOSED polygon back.
//   • rectangle mode — drag anywhere on empty canvas to DRAW a box (any
//     direction), or grab the body/corners to move and resize it (free or 1:1).
//
// Gesture note: tap and pan share one detector, and the pan recognizer wins
// the arena as soon as a finger drifts past kTouchSlop — so a "tap" from a
// real thumb frequently arrives as a pan. Both modes therefore treat a pan
// that grabbed nothing and barely moved as a tap; without that, polygon points
// simply never appeared.
//
// All coordinates are NORMALIZED [0,1] in rotated-image space (the domain
// contract, image_edit.dart) — this widget converts to pixels only for
// painting and hit-testing. It owns only the DRAFT; the applied edit lives in
// the screen's per-image state.
//
// AppliedCropOverlayPainter (bottom of file) is the display-only companion:
// it shows an APPLIED polygon as the export will look (white outside), so the
// user sees the result without a bake pass.
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/image_edit.dart';

/// Which crop tool the editor is running.
enum PrepCropMode { polygon, rectangle }

/// Hit-test radius for grabbing a vertex / handle, in logical pixels.
const double _kGrabRadiusPx = 24;

/// A pan that grabbed nothing and travelled less than this is treated as a
/// TAP. The pan recognizer wins the gesture arena as soon as a finger drifts
/// past kTouchSlop (~18px), which is routine for a real thumb — without this
/// fallback those taps were swallowed and no polygon point was ever added.
const double _kTapSlopPx = 36;

class PrepCropEditor extends StatefulWidget {
  const PrepCropEditor({
    super.key,
    required this.mode,
    required this.onApplyPolygon,
    required this.onApplyRect,
    required this.onCancel,
    this.initialPolygon,
    this.initialRect,
  });

  final PrepCropMode mode;

  /// Called with the CLOSED polygon (≥3 normalized vertices) on Apply.
  final ValueChanged<List<EditPoint>> onApplyPolygon;
  final ValueChanged<RectCrop> onApplyRect;
  final VoidCallback onCancel;

  /// Seed for re-editing an already-applied crop.
  final List<EditPoint>? initialPolygon;
  final RectCrop? initialRect;

  @override
  PrepCropEditorState createState() => PrepCropEditorState();
}

/// PUBLIC so the host screen can reach [PrepCropEditorState.applyDraft] through
/// a [GlobalKey] — "Generate" with an open editor commits the crop instead of
/// silently doing nothing.
class PrepCropEditorState extends State<PrepCropEditor> {
  late List<EditPoint> _points;
  late bool _closed;
  int? _selected;
  int? _dragIndex;

  /// Where the current pan began, so a pan that grabbed no vertex and barely
  /// moved can be replayed as a tap on release (see [_kTapSlopPx]).
  Offset? _panStart;

  /// Most recent pan position — onPanEnd carries no coordinates, so the travel
  /// distance has to be measured from what onPanUpdate last saw. Stays null
  /// when the gesture never moved at all, which also counts as a tap.
  Offset? _lastPanPosition;

  late RectCrop _rect;
  bool _square = false;
  _RectHandle? _rectDrag;
  Offset? _rectDragStart;
  RectCrop? _rectAtDragStart;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialPolygon;
    _points = [...?seed];
    _closed = seed != null && seed.length >= 3;
    _rect = widget.initialRect ??
        const RectCrop(left: 0.1, top: 0.1, width: 0.8, height: 0.8);
  }

  // ── Coordinate helpers ─────────────────────────────────────────────────────

  EditPoint _toNorm(Offset local, Size size) =>
      EditPoint(local.dx / size.width, local.dy / size.height).clamped();

  Offset _toPx(EditPoint p, Size size) =>
      Offset(p.x * size.width, p.y * size.height);

  int? _vertexNear(Offset local, Size size) {
    for (var i = 0; i < _points.length; i++) {
      if ((_toPx(_points[i], size) - local).distance <= _kGrabRadiusPx) {
        return i;
      }
    }
    return null;
  }

  /// The segment whose midpoint is nearest [local] (within grab range).
  int? _segmentNear(Offset local, Size size) {
    if (_points.length < 2) return null;
    int? best;
    var bestDistance = _kGrabRadiusPx;
    final count = _closed ? _points.length : _points.length - 1;
    for (var i = 0; i < count; i++) {
      final a = _toPx(_points[i], size);
      final b = _toPx(_points[(i + 1) % _points.length], size);
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final d = (mid - local).distance;
      if (d <= bestDistance) {
        best = i;
        bestDistance = d;
      }
    }
    return best;
  }

  // ── Polygon gestures ───────────────────────────────────────────────────────

  void _polygonTap(Offset local, Size size) {
    setState(() {
      if (!_closed) {
        if (_points.length >= 3 &&
            (_toPx(_points.first, size) - local).distance <= _kGrabRadiusPx) {
          _closed = true;
          _selected = null;
          return;
        }
        _points = [..._points, _toNorm(local, size)];
        return;
      }
      _selected = _vertexNear(local, size);
    });
  }

  void _polygonLongPress(Offset local, Size size) {
    final segment = _segmentNear(local, size);
    if (segment == null) return;
    setState(() {
      _points = insertMidpoint(_points, segment);
      _selected = segment + 1;
    });
  }

  void _undoPoint() {
    if (_points.isEmpty) return;
    setState(() {
      _points = _points.sublist(0, _points.length - 1);
      _selected = null;
    });
  }

  void _deleteSelected() {
    final index = _selected;
    if (index == null) return;
    setState(() {
      _points = removePointAt(_points, index);
      _selected = null;
    });
  }

  // ── Rectangle gestures ─────────────────────────────────────────────────────

  /// The handle a drag at [local] should grab, or null when the touch is
  /// outside the box entirely — the caller then starts a NEW rect there.
  _RectHandle? _handleNear(Offset local, Size size) {
    final r = _rectPx(size);
    final corners = {
      _RectHandle.topLeft: r.topLeft,
      _RectHandle.topRight: r.topRight,
      _RectHandle.bottomLeft: r.bottomLeft,
      _RectHandle.bottomRight: r.bottomRight,
    };
    for (final entry in corners.entries) {
      if ((entry.value - local).distance <= _kGrabRadiusPx) return entry.key;
    }
    return r.contains(local) ? _RectHandle.body : null;
  }

  /// Begins a rectangle drag. A touch on the existing box moves/resizes it; a
  /// touch anywhere else DRAWS A NEW BOX from that anchor — previously this
  /// returned null and the drag was silently discarded, so the rect could only
  /// ever be nudged from its hardcoded starting position.
  void _rectPanStart(Offset local, Size size) {
    final handle = _handleNear(local, size);
    _rectDragStart = local;
    if (handle != null) {
      _rectDrag = handle;
      _rectAtDragStart = _rect;
      return;
    }
    _rectDrag = _RectHandle.draw;
    _rectAtDragStart = _rect; // restored if the draw ends degenerate
  }

  /// Live rect for a draw-from-anchor drag: anchor and current point are
  /// opposite corners, normalized so dragging in ANY direction works (not just
  /// down-and-right).
  void _rectDrawUpdate(Offset local, Size size) {
    final start = _rectDragStart;
    if (start == null) return;
    final a = _toNorm(start, size);
    final b = _toNorm(local, size);
    var left = math.min(a.x, b.x);
    var top = math.min(a.y, b.y);
    var width = (a.x - b.x).abs();
    var height = (a.y - b.y).abs();
    if (_square) {
      final side = math.min(width, height);
      // Keep the corner under the finger on the shrinking axis.
      if (b.x < a.x) left = a.x - side;
      if (b.y < a.y) top = a.y - side;
      width = side;
      height = side;
    }
    setState(() =>
        _rect = RectCrop(left: left, top: top, width: width, height: height));
  }

  /// Discards a draw that never became a usable box (a stray tap on empty
  /// canvas), restoring whatever rect was there before.
  void _rectPanEnd() {
    if (_rectDrag == _RectHandle.draw) {
      final before = _rectAtDragStart;
      if (before != null && (_rect.width < 0.02 || _rect.height < 0.02)) {
        setState(() => _rect = before);
      }
    }
    _rectDrag = null;
    _rectDragStart = null;
    _rectAtDragStart = null;
  }

  Rect _rectPx(Size size) => Rect.fromLTWH(
        _rect.left * size.width,
        _rect.top * size.height,
        _rect.width * size.width,
        _rect.height * size.height,
      );

  void _rectPanUpdate(Offset local, Size size) {
    final handle = _rectDrag;
    final start = _rectDragStart;
    final at = _rectAtDragStart;
    if (handle == null || start == null || at == null) return;

    if (handle == _RectHandle.draw) {
      _rectDrawUpdate(local, size);
      return;
    }

    final dx = (local.dx - start.dx) / size.width;
    final dy = (local.dy - start.dy) / size.height;

    double left = at.left,
        top = at.top,
        right = at.left + at.width,
        bottom = at.top + at.height;
    switch (handle) {
      case _RectHandle.draw:
        return; // handled above
      case _RectHandle.body:
        left = (at.left + dx).clamp(0.0, 1.0 - at.width);
        top = (at.top + dy).clamp(0.0, 1.0 - at.height);
        setState(() => _rect =
            RectCrop(left: left, top: top, width: at.width, height: at.height));
        return;
      case _RectHandle.topLeft:
        left = (at.left + dx).clamp(0.0, right - 0.05);
        top = (at.top + dy).clamp(0.0, bottom - 0.05);
      case _RectHandle.topRight:
        right = (right + dx).clamp(left + 0.05, 1.0);
        top = (at.top + dy).clamp(0.0, bottom - 0.05);
      case _RectHandle.bottomLeft:
        left = (at.left + dx).clamp(0.0, right - 0.05);
        bottom = (bottom + dy).clamp(top + 0.05, 1.0);
      case _RectHandle.bottomRight:
        right = (right + dx).clamp(left + 0.05, 1.0);
        bottom = (bottom + dy).clamp(top + 0.05, 1.0);
    }
    var width = right - left;
    var height = bottom - top;
    if (_square) {
      // 1:1 in NORMALIZED terms of the displayed (rotated) image — coerce to
      // the smaller side, anchored at the corner being dragged.
      final side = width < height ? width : height;
      if (handle == _RectHandle.topLeft || handle == _RectHandle.bottomLeft) {
        left = right - side;
      }
      if (handle == _RectHandle.topLeft || handle == _RectHandle.topRight) {
        top = bottom - side;
      }
      width = side;
      height = side;
    }
    setState(() =>
        _rect = RectCrop(left: left, top: top, width: width, height: height));
  }

  // ── Applying from outside ──────────────────────────────────────────────────

  /// Commits the current draft exactly as the Apply chip would, and reports
  /// whether there WAS one to commit.
  ///
  /// The host screen calls this when the user presses "Generate 3D Model" with
  /// the editor still open — the obvious reading of that press is "use what I
  /// just drew", and the alternative (a dead CTA) is how this screen used to
  /// look broken. A polygon of fewer than 3 points is not a shape yet, so that
  /// is the one case this refuses; closing an un-closed 3+ point outline is
  /// implicit, since Apply is only offered closed anyway.
  bool applyDraft() {
    if (widget.mode == PrepCropMode.rectangle) {
      widget.onApplyRect(_rect);
      return true;
    }
    if (_points.length < 3) return false;
    _closed = true;
    widget.onApplyPolygon(_points);
    return true;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final isPolygon = widget.mode == PrepCropMode.polygon;
      return Stack(fit: StackFit.expand, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Report the DOWN position, not the post-slop one. With the default
          // (.start) a grabbed corner jumps ~18px the instant the drag is
          // recognized, because the slop travel is discarded — very visible
          // when you are trying to place a crop edge precisely.
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: isPolygon ? (d) => _polygonTap(d.localPosition, size) : null,
          onLongPressStart: isPolygon
              ? (d) => _polygonLongPress(d.localPosition, size)
              : null,
          onPanStart: (d) {
            _panStart = d.localPosition;
            if (isPolygon) {
              _dragIndex = _vertexNear(d.localPosition, size);
              if (_dragIndex != null) setState(() => _selected = _dragIndex);
            } else {
              _rectPanStart(d.localPosition, size);
            }
          },
          onPanUpdate: (d) {
            _lastPanPosition = d.localPosition;
            if (isPolygon) {
              final index = _dragIndex;
              if (index == null) return;
              setState(() => _points =
                  movePoint(_points, index, _toNorm(d.localPosition, size)));
            } else {
              _rectPanUpdate(d.localPosition, size);
            }
          },
          onPanEnd: (_) {
            if (isPolygon) {
              // The pan recognizer claims any touch that drifts past
              // kTouchSlop, so a real finger "tap" often arrives here rather
              // than at onTapUp. If it grabbed no vertex and barely moved,
              // it WAS a tap — replay it, otherwise the point is lost and the
              // canvas appears dead.
              final start = _panStart;
              if (_dragIndex == null &&
                  start != null &&
                  (_lastPanPosition == null ||
                      (_lastPanPosition! - start).distance <= _kTapSlopPx)) {
                _polygonTap(start, size);
              }
            } else {
              _rectPanEnd();
            }
            _dragIndex = null;
            _panStart = null;
            _lastPanPosition = null;
          },
          child: CustomPaint(
            painter: isPolygon
                ? _PolygonDraftPainter(
                    points: _points,
                    closed: _closed,
                    selected: _selected,
                  )
                : _RectDraftPainter(rect: _rect),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: isPolygon ? _polygonActions() : _rectActions(),
          ),
        ),
      ]);
    });
  }

  Widget _polygonActions() {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      alignment: WrapAlignment.center,
      children: [
        if (!_closed)
          _chip(
            key: const ValueKey('prep_poly_close'),
            label: 'Close',
            icon: Icons.check_circle_outline,
            onTap: _points.length >= 3
                ? () => setState(() => _closed = true)
                : null,
          ),
        if (!_closed)
          _chip(
            key: const ValueKey('prep_poly_undo'),
            label: 'Undo',
            icon: Icons.undo,
            onTap: _points.isNotEmpty ? _undoPoint : null,
          ),
        if (_selected != null && _points.length > 3)
          _chip(
            key: const ValueKey('prep_poly_delete'),
            label: 'Delete point',
            icon: Icons.remove_circle_outline,
            onTap: _deleteSelected,
          ),
        if (_closed)
          _chip(
            key: const ValueKey('prep_poly_apply'),
            label: 'Apply',
            icon: Icons.check,
            emphasized: true,
            onTap: () => widget.onApplyPolygon(_points),
          ),
        _chip(
          key: const ValueKey('prep_crop_cancel'),
          label: 'Cancel',
          icon: Icons.close,
          onTap: widget.onCancel,
        ),
      ],
    );
  }

  Widget _rectActions() {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      alignment: WrapAlignment.center,
      children: [
        _chip(
          key: const ValueKey('prep_rect_aspect'),
          label: _square ? '1:1' : 'Free',
          icon: Icons.aspect_ratio,
          onTap: () => setState(() {
            _square = !_square;
            if (_square) {
              final side =
                  _rect.width < _rect.height ? _rect.width : _rect.height;
              _rect = RectCrop(
                left: _rect.left,
                top: _rect.top,
                width: side,
                height: side,
              );
            }
          }),
        ),
        _chip(
          key: const ValueKey('prep_rect_apply'),
          label: 'Apply',
          icon: Icons.check,
          emphasized: true,
          onTap: () => widget.onApplyRect(_rect),
        ),
        _chip(
          key: const ValueKey('prep_crop_cancel'),
          label: 'Cancel',
          icon: Icons.close,
          onTap: widget.onCancel,
        ),
      ],
    );
  }

  Widget _chip({
    required Key key,
    required String label,
    required IconData icon,
    VoidCallback? onTap,
    bool emphasized = false,
  }) {
    final enabled = onTap != null;
    return Material(
      key: key,
      color: emphasized
          ? AppColors.mirageRed
          : Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 16, color: enabled ? Colors.white : Colors.white38),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
                fontSize: 13,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

enum _RectHandle {
  body,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,

  /// Drawing a brand-new box from an anchor, not resizing an existing one.
  draw,
}

// ── Painters ─────────────────────────────────────────────────────────────────

Path _polygonPath(List<EditPoint> points, Size size, {required bool close}) {
  final path = Path()
    ..moveTo(points.first.x * size.width, points.first.y * size.height);
  for (final p in points.skip(1)) {
    path.lineTo(p.x * size.width, p.y * size.height);
  }
  if (close) path.close();
  return path;
}

class _PolygonDraftPainter extends CustomPainter {
  _PolygonDraftPainter({
    required this.points,
    required this.closed,
    required this.selected,
  });

  final List<EditPoint> points;
  final bool closed;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = AppColors.mirageRed;

    if (points.length >= 2) {
      canvas.drawPath(_polygonPath(points, size, close: closed), outline);
    }

    if (closed) {
      // Dim everything OUTSIDE the polygon — the live "what gets removed" cue.
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        _polygonPath(points, size, close: true),
      );
      canvas.drawPath(
        outside,
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
    }

    for (var i = 0; i < points.length; i++) {
      final center =
          Offset(points[i].x * size.width, points[i].y * size.height);
      final isFirst = i == 0 && !closed;
      final isSelected = i == selected;
      canvas.drawCircle(
        center,
        isFirst || isSelected ? 9 : 6,
        Paint()..color = isSelected ? Colors.white : AppColors.mirageRed,
      );
      if (isFirst && points.length >= 3) {
        // The "tap here to close" affordance.
        canvas.drawCircle(
          center,
          13,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PolygonDraftPainter old) =>
      old.points != points || old.closed != closed || old.selected != selected;
}

class _RectDraftPainter extends CustomPainter {
  _RectDraftPainter({required this.rect});

  final RectCrop rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(r),
    );
    canvas.drawPath(
        outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.mirageRed,
    );
    for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(corner, 7, Paint()..color = AppColors.mirageRed);
    }
  }

  @override
  bool shouldRepaint(_RectDraftPainter old) => old.rect != rect;
}

/// Display-only overlay for an image whose crop is APPLIED (no editor open):
/// a polygon renders as the export will — solid white outside, with the
/// padded-crop boundary hinted; a rectangle dims the discarded margins.
class AppliedCropOverlayPainter extends CustomPainter {
  AppliedCropOverlayPainter({this.polygon, this.rect});

  final List<EditPoint>? polygon;
  final RectCrop? rect;

  @override
  void paint(Canvas canvas, Size size) {
    final polygonPoints = polygon;
    if (polygonPoints != null && polygonPoints.length >= 3) {
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        _polygonPath(polygonPoints, size, close: true),
      );
      // The export's white fill, shown as-is (this is what Meshy receives).
      canvas.drawPath(outside, Paint()..color = Colors.white);

      final b = polygonBounds(polygonPoints);
      final bounds = Rect.fromLTRB(
        b.left * size.width,
        b.top * size.height,
        b.right * size.width,
        b.bottom * size.height,
      );
      final pad =
          (bounds.width > bounds.height ? bounds.width : bounds.height) *
              kPolygonCropPaddingFraction;
      canvas.drawRect(
        bounds.inflate(pad).intersect(Offset.zero & size),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.textMuted,
      );
      return;
    }

    final r = rect;
    if (r != null && !r.isFullImage) {
      final kept = Rect.fromLTWH(
        r.left * size.width,
        r.top * size.height,
        r.width * size.width,
        r.height * size.height,
      );
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(kept),
      );
      canvas.drawPath(
          outside, Paint()..color = Colors.black.withValues(alpha: 0.7));
      canvas.drawRect(
        kept,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = AppColors.textMuted,
      );
    }
  }

  @override
  bool shouldRepaint(AppliedCropOverlayPainter old) =>
      old.polygon != polygon || old.rect != rect;
}
