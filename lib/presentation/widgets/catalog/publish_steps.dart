// lib/presentation/widgets/catalog/publish_steps.dart
//
// The step-by-step line under the publish progress bar: what the run is doing
// NOW, what it has done, and what is left — for a publish and, in reverse, for
// a takedown. Shown on every publish screen (owner, rep, admin), because it is
// part of the one PublishBody they share.
//
// Derived ONLY from the run the server reports (state + counts); nothing here
// is a timer pretending to know progress.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/publish_status.dart';

/// The labels for one run, in order. The third carries the live count.
List<String> publishStepLabels(PublishRun? run) {
  final counts = run?.counts ?? const PublishRunCounts();
  final unpublishing = run?.mode.isUnpublish ?? false;
  final tally = counts.total > 0 ? ' (${counts.synced}/${counts.total})' : '';
  return unpublishing
      ? [
          'Request sent',
          'Switching the page off',
          'Removing dishes$tally',
          'Menu is offline',
        ]
      : [
          'Request sent',
          'Preparing the menu',
          'Uploading dishes$tally',
          'Menu is live',
        ];
}

/// Which step is ACTIVE (0-based). Steps before it are done; the last step is
/// reached only when the run has finished, which this card never shows (the
/// success card takes over), so an in-flight run tops out at 2.
int publishActiveStep(PublishRun? run) {
  if (run == null) return 0;
  final counts = run.counts;
  if (run.state == PublishRunState.succeeded) return 3;
  if (run.state == PublishRunState.queued) return 1;
  // Running: the planner has not counted anything yet → still preparing.
  if (counts.total == 0) return 1;
  return 2;
}

class PublishStepTimeline extends StatelessWidget {
  const PublishStepTimeline({super.key, required this.run});

  final PublishRun? run;

  @override
  Widget build(BuildContext context) {
    final labels = publishStepLabels(run);
    final active = publishActiveStep(run);
    return Column(
      key: const ValueKey('publish_step_timeline'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < labels.length; i++)
          _StepRow(
            label: labels[i],
            done: i < active,
            active: i == active,
            isLast: i == labels.length - 1,
          ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.done,
    required this.active,
    required this.isLast,
  });

  final String label;
  final bool done;
  final bool active;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final color = done
        ? AppColors.success
        : active
            ? AppColors.royalGold
            : AppColors.textMuted;
    final marker = done
        ? const Icon(Icons.check_circle,
            key: ValueKey('done'), size: 18, color: AppColors.success)
        : active
            ? const _Pulse(key: ValueKey('active'))
            : const Icon(Icons.radio_button_unchecked,
                key: ValueKey('todo'), size: 18, color: AppColors.textMuted);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                // The marker swaps with a scale-and-fade as the step finishes.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: marker,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: done
                        ? AppColors.success
                        : AppColors.textMuted.withValues(alpha: 0.3),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.md),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: TextStyle(
                  fontSize: 14,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(label),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The active step's marker: a gently breathing dot. Honours the platform's
/// "reduce motion" setting (and so stays still in widget tests that ask).
class _Pulse extends StatefulWidget {
  const _Pulse({super.key});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = 1;
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.8, end: 1).animate(_controller),
          child: Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: AppColors.royalGold,
              shape: BoxShape.circle,
            ),
          ),
        ),
      );
}
