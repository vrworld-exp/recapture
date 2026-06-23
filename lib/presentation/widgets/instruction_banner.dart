// lib/presentation/widgets/instruction_banner.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/capture_instruction.dart';

/// The single authoritative instruction pill for the Level A HUD. Exactly one
/// pill exists at a time: a changed instruction [CaptureInstruction.id] crossfades
/// the old out and the new in (same slot — never stacked, never queued), text is
/// capped at two lines, and the pill never spans edge-to-edge. A null/empty
/// instruction fades the pill out to hidden.
///
/// It DISPLAYS the supplied instruction only — it does not select or prioritize
/// instructions (that is the parent's job). Hit-test transparent, so it never
/// swallows taps meant for the capture chrome.
///
/// Behaviour:
/// - Same [CaptureInstruction.id] re-emitted ⇒ no re-animation (a sustained cue
///   stays put). A severity/message restyle under the same id applies instantly.
/// - Rapid different instructions ⇒ coalesced via a short debounce
///   ([coalesceWindow]); only the latest is shown (pending is replaced, never
///   queued), so intermediate messages are not flashed.
/// - Reduce-motion ⇒ instant swap (no crossfade); coalescing still applies.
class InstructionBanner extends StatefulWidget {
  const InstructionBanner({
    super.key,
    required this.instruction,
    this.crossfade = const Duration(milliseconds: 220),
    this.coalesceWindow = const Duration(milliseconds: 120),
    this.maxWidthFactor = 0.8,
  });

  /// The current instruction, or null to hide the banner.
  final CaptureInstruction? instruction;

  /// Crossfade duration for a changed instruction (ignored under reduce-motion).
  final Duration crossfade;

  /// Debounce window that coalesces rapid changes to the latest.
  final Duration coalesceWindow;

  /// Max pill width as a fraction of screen width (keeps the pill compact).
  final double maxWidthFactor;

  @override
  State<InstructionBanner> createState() => _InstructionBannerState();
}

class _InstructionBannerState extends State<InstructionBanner> {
  /// The instruction currently rendered (vs. the latest incoming on the widget).
  CaptureInstruction? _displayed;

  /// Debounce timer for a pending id change; replaced (not queued) on each change.
  Timer? _applyTimer;

  @override
  void initState() {
    super.initState();
    _displayed = widget.instruction; // first mount shows immediately, no debounce
  }

  @override
  void didUpdateWidget(InstructionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.instruction;

    // Same id ⇒ no crossfade. Apply a severity/message restyle instantly and
    // cancel any pending divergent change (the parent settled back to this id).
    if (incoming?.id == _displayed?.id) {
      if (incoming != _displayed) {
        _applyTimer?.cancel();
        _applyTimer = null;
        setState(() => _displayed = incoming);
      }
      return;
    }

    // Id differs (incl. null↔non-null) ⇒ debounce, latest-wins. Restart the
    // timer on every change so only the final instruction in a burst is applied.
    _applyTimer?.cancel();
    _applyTimer = Timer(widget.coalesceWindow, () {
      _applyTimer = null;
      if (!mounted) return;
      setState(() => _displayed = widget.instruction); // newest at fire time
    });
  }

  @override
  void dispose() {
    _applyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final displayed = _displayed;
    final hasMessage =
        displayed != null && displayed.message.trim().isNotEmpty;

    // Lower-third, centered, clear of the bottom controls. Hit-test transparent.
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.sizeOf(context).height * 0.22,
      child: IgnorePointer(
        child: Center(
          child: AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : widget.crossfade,
            // A single child occupies the slot; during a transition the outgoing
            // and incoming briefly crossfade in the SAME centered slot — they are
            // never stacked vertically and never queue.
            child: hasMessage
                ? _Pill(
                    // Key by id so AnimatedSwitcher only transitions on a real
                    // change; same-id rebuilds reuse the child (no re-animation).
                    key: ValueKey<String>(displayed.id),
                    instruction: displayed,
                    maxWidthFactor: widget.maxWidthFactor,
                  )
                : const SizedBox.shrink(key: ValueKey<String>('__none__')),
          ),
        ),
      ),
    );
  }
}

/// The pill itself: an elevated dark surface, white centred text capped at two
/// lines with ellipsis, constrained to [maxWidthFactor] of the screen width.
/// [InstructionSeverity.warning] adds a subtle Mirage Red border/tint (not a
/// full red fill) to stay readable and on-brand.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.instruction,
    required this.maxWidthFactor,
  });

  final CaptureInstruction instruction;
  final double maxWidthFactor;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * maxWidthFactor;
    final isWarning = instruction.severity == InstructionSeverity.warning;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface1.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: isWarning
              ? Border.all(color: AppColors.mirageRed, width: 1.5)
              : null,
        ),
        child: Text(
          instruction.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}
