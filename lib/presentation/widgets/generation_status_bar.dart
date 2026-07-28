// lib/presentation/widgets/generation_status_bar.dart
//
// The app-wide "something is being built" bar — the Instagram-upload shape,
// applied to 3D-model generation.
//
// Mounted ABOVE the navigator (via MaterialApp.router's `builder`) so it is the
// same bar on every screen rather than one banner per route, and so it PUSHES
// content down instead of overlaying an AppBar.
//
// Copy discipline is the same rule ModelBuildingScreen follows: a failure gets
// one owner-safe sentence. Never a code, never a URL, never the name of the
// vendor that actually builds the model.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/routes/app_router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../application/projects/generation_tracker_notifier.dart';
import '../screens/projects/model_building_screen.dart';

/// Which of the bar's four faces to show.
enum GenerationBannerKind { hidden, running, succeeded, failed }

/// The bar's whole rendering decision, as a value.
///
/// Pulled out of the widget so the copy rules — what a lone run says versus
/// three of them, when a percent may be shown, what is dismissible — are
/// testable without pumping a widget tree.
@immutable
class GenerationBannerModel {
  const GenerationBannerModel({
    required this.kind,
    this.title = '',
    this.percent,
    this.projectId,
    this.projectName,
    this.isDismissible = false,
  });

  static const hidden =
      GenerationBannerModel(kind: GenerationBannerKind.hidden);

  final GenerationBannerKind kind;
  final String title;

  /// Only ever set for a SINGLE running generation whose percent the server has
  /// actually reported. Null renders an indeterminate bar — never a made-up
  /// number, and never an average across several runs.
  final int? percent;

  /// The project to open on tap, when the bar names exactly one. Null when it
  /// aggregates several — that taps through to the Projects Hub instead.
  final String? projectId;
  final String? projectName;

  /// Failures carry an explicit dismiss: nothing clears them on a timer, because
  /// a failure the user never saw is the worst outcome this feature can have.
  final bool isDismissible;

  bool get isVisible => kind != GenerationBannerKind.hidden;
}

/// The pure banner decision for a tracker snapshot.
///
/// Precedence is running → succeeded → failed/gave-up, deliberately in that
/// order. Running wins because it is the live thing. Success is placed ABOVE
/// failure so that a success (which self-clears after a minute) is never hidden
/// behind a failure (which never clears until dismissed) and lost forever.
GenerationBannerModel generationBannerFor(GenerationTrackerState state) {
  final running = state.running;
  if (running.length == 1) {
    final entry = running.first;
    return GenerationBannerModel(
      kind: GenerationBannerKind.running,
      title: entry.percent == null
          ? 'Creating your 3D model'
          : 'Creating your 3D model · ${entry.percent}%',
      percent: entry.percent,
      projectId: entry.projectId,
      projectName: entry.projectName,
    );
  }
  if (running.length > 1) {
    // No percent at all here: averaging two independent runs would report a
    // number neither of them is at.
    return GenerationBannerModel(
      kind: GenerationBannerKind.running,
      title: 'Creating ${running.length} 3D models',
    );
  }

  final succeeded = state.withStatus(TrackedGenerationStatus.succeeded);
  if (succeeded.isNotEmpty) {
    final single = succeeded.length == 1 ? succeeded.first : null;
    return GenerationBannerModel(
      kind: GenerationBannerKind.succeeded,
      title: single != null
          ? 'Your 3D model is ready'
          : 'Your ${succeeded.length} 3D models are ready',
      projectId: single?.projectId,
      projectName: single?.projectName,
    );
  }

  final failed = [
    ...state.withStatus(TrackedGenerationStatus.failed),
    ...state.withStatus(TrackedGenerationStatus.givenUp),
  ];
  if (failed.isNotEmpty) {
    final first = failed.first;
    final single = failed.length == 1;
    return GenerationBannerModel(
      kind: GenerationBannerKind.failed,
      title: !single
          ? "We couldn't create some of your 3D models"
          : first.status == TrackedGenerationStatus.givenUp
              // Not "it failed" — we do not know that. We know we stopped
              // asking, and saying so beats a bar that waits forever.
              ? "We've stopped checking on your 3D model"
              : "We couldn't create your 3D model",
      projectId: single ? first.projectId : null,
      projectName: single ? first.projectName : null,
      isDismissible: true,
    );
  }

  return GenerationBannerModel.hidden;
}

/// Wraps the app's navigator with the generation status bar.
///
/// When there is nothing to show it returns [child] completely untouched — not
/// a `Column` with a zero-height first slot. That is the overwhelmingly common
/// case, and it means every existing screen and every existing widget test sees
/// exactly the layout it saw before this feature existed.
class GenerationStatusBar extends ConsumerWidget {
  const GenerationStatusBar({
    super.key,
    required this.child,
    @visibleForTesting this.onOpen,
  });

  final Widget child;

  /// Test seam for the tap destination. Production leaves it null and routes
  /// through the app router — see [_open] for why this cannot simply be
  /// `Navigator.of(context)`.
  final void Function(GenerationBannerModel banner)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = generationBannerFor(ref.watch(generationTrackerProvider));
    if (!banner.isVisible) return child;

    return Column(
      children: [
        _Banner(
          banner: banner,
          onTap: () => _open(ref, banner),
          onDismiss: banner.isDismissible && banner.projectId != null
              ? () => ref
                  .read(generationTrackerProvider.notifier)
                  .dismiss(banner.projectId!)
              : null,
        ),
        Expanded(child: child),
      ],
    );
  }

  /// Opens whatever the bar is pointing at.
  ///
  /// `Navigator.of(context)` is NOT usable here: this widget sits ABOVE the
  /// navigator in the tree (MaterialApp.router hands its `builder` the
  /// Navigator as a child), so there is no Navigator ancestor to find — and
  /// there is no go_router context either. Both destinations therefore go
  /// through the router instance: its own navigator key for the push, and
  /// `go` for the route.
  void _open(WidgetRef ref, GenerationBannerModel banner) {
    if (onOpen != null) {
      onOpen!(banner);
      return;
    }
    // A tap is an acknowledgement — a finished model the user has now been
    // taken to should not keep announcing itself.
    if (banner.kind == GenerationBannerKind.succeeded &&
        banner.projectId != null) {
      ref.read(generationTrackerProvider.notifier).dismiss(banner.projectId!);
    }

    final router = ref.read(appRouterProvider);
    final projectId = banner.projectId;
    if (projectId == null) {
      // Several runs at once — there is no single screen that shows them all,
      // so the Hub is the honest destination.
      router.go(AppRoutes.projects);
      return;
    }
    // ModelBuildingScreen already handles running, ready AND failed, so one
    // destination covers every kind of bar.
    router.routerDelegate.navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => ModelBuildingScreen(
          projectId: projectId,
          projectName: banner.projectName ?? kUnnamedTrackedProject,
        ),
      ),
    );
  }
}

/// The bar itself. A FIXED height per state — a bar that grows and shrinks
/// between polls would reflow every screen underneath it on every tick.
class _Banner extends StatelessWidget {
  const _Banner({required this.banner, required this.onTap, this.onDismiss});

  static const double _rowHeight = 48;
  static const double _progressHeight = 3;

  final GenerationBannerModel banner;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  Color get _accent => switch (banner.kind) {
        GenerationBannerKind.succeeded => AppColors.success,
        GenerationBannerKind.failed => AppColors.error,
        _ => AppColors.royalGold,
      };

  IconData get _icon => switch (banner.kind) {
        GenerationBannerKind.succeeded => Icons.check_circle_outline,
        GenerationBannerKind.failed => Icons.error_outline,
        _ => Icons.auto_awesome_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = banner.kind == GenerationBannerKind.running;

    return Material(
      color: AppColors.surface1,
      child: SafeArea(
        // Only the top inset: the bar clears the status bar and nothing else.
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onTap,
              child: SizedBox(
                height: _rowHeight,
                child: Row(
                  children: [
                    const SizedBox(width: AppSpacing.lg),
                    Icon(_icon, size: 18, color: _accent),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        banner.title,
                        key: const Key('generation_status_bar_title'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: AppColors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (onDismiss != null)
                      IconButton(
                        key: const Key('generation_status_bar_dismiss'),
                        icon: const Icon(Icons.close, size: 18),
                        color: AppColors.textSecondary,
                        onPressed: onDismiss,
                        tooltip: 'Dismiss',
                      )
                    else
                      const SizedBox(width: AppSpacing.lg),
                  ],
                ),
              ),
            ),
            // Determinate only when the server has actually said a number;
            // otherwise indeterminate, which is the truth.
            if (isRunning)
              SizedBox(
                height: _progressHeight,
                child: LinearProgressIndicator(
                  key: const Key('generation_status_bar_progress'),
                  value: banner.percent == null ? null : banner.percent! / 100,
                  minHeight: _progressHeight,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
