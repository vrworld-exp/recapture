// lib/presentation/widgets/model_picker_field.dart
//
// "Which capture, and which of its models" — the one widget behind BOTH the
// add-product form's 3D source field and the change-3D-model screen.
//
// One widget rather than two copies because the pair IS the feature: a capture
// holds a HISTORY of models (the auto generation, every regenerate, the
// `optimized` derivative), and the whole point of this work is that the user
// sees all of them and says which one they mean. A second copy would drift on
// exactly the details that matter — which records are selectable, which are
// merely shown, and what a pending one says.
//
// It is a pure OBSERVER of [ownerModelHistoryProvider], which already polls the
// owner route with backoff and a hard cap and is auto-disposed with the screen.
// No second fetch path, no second polling loop, and never `/admin` — an owner
// gets a 404 there by design, and so does an admin who does not own the capture.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../application/projects/owner_model_history_notifier.dart';
import '../../application/projects/projects_notifier.dart';
import '../../domain/entities/project_model.dart';
import '../screens/projects/preview_gallery_screen.dart' show failureCopy;
import 'app_button.dart';
import 'app_loading_indicator.dart';
import 'model_choice_tile.dart';

/// Widest the picker's own column is ever allowed to get.
///
/// A browser window is 1200-plus points wide and a row of stretched tiles at
/// that width puts the thumbnail and the Preview button at opposite ends of the
/// screen. Decided from the CONSTRAINTS, never from `kIsWeb`: a small browser
/// window is a phone layout, and a tablet APK is not a phone.
const double kModelPickerMaxWidth = 640;

/// Past this many tiles the list stops growing the page and becomes a bounded
/// panel that scrolls inside itself.
///
/// Chosen, not derived: four tiles is about a phone screen's worth. Below it the
/// list inlines (shrinkWrap, no physics of its own) so the form scrolls as one
/// surface; above it a nested scroller is the lesser evil against a form that is
/// ten screens long before the name field.
const int kModelPickerInlineLimit = 4;

/// Roughly one tile plus its separator — only used to bound the panel above.
const double _kTileExtent = 96;

class ModelPickerField extends ConsumerStatefulWidget {
  const ModelPickerField({
    super.key,
    required this.selectedProjectId,
    required this.selectedModelId,
    required this.onProjectChanged,
    required this.onModelChanged,
    required this.onPreview,
    this.currentModelId,
    this.enabled = true,
    this.autoSelectNewest = true,
  });

  /// The chosen capture, or null when nothing is chosen yet.
  final String? selectedProjectId;

  /// The chosen model. Owned by the PARENT, because it is what the parent posts
  /// — this widget never holds the answer it is collecting.
  final String? selectedModelId;

  /// Fires with the new capture id. The parent MUST clear the model selection in
  /// the same `setState`; a model id from the previous capture reaching a submit
  /// is the one bug this feature can introduce.
  final ValueChanged<String?> onProjectChanged;

  final ValueChanged<String?> onModelChanged;

  /// Opens one model in the 3D viewer. The parent owns the push so the viewer
  /// lands on the right navigator, and so returning leaves this widget's state
  /// (and the form around it) untouched.
  final ValueChanged<ProjectModelView> onPreview;

  /// The model the product uses TODAY, when there is one and the list on screen
  /// is its own capture's. Marks that tile **Current**, and turns "it is not in
  /// this list" into a plain sentence instead of a silent re-pick.
  final String? currentModelId;

  final bool enabled;

  /// Preselect the newest viewable model whenever nothing is selected (D2).
  ///
  /// That is exactly what the app chose implicitly before this screen existed,
  /// so a user who does not care about the choice loses no taps — the difference
  /// is that the choice is now visible and changeable.
  final bool autoSelectNewest;

  @override
  ConsumerState<ModelPickerField> createState() => _ModelPickerFieldState();
}

class _ModelPickerFieldState extends ConsumerState<ModelPickerField> {
  /// Guards against queueing a second preselect in the same frame batch. The
  /// selection itself is the real stop condition — once it is non-null the
  /// branch below never runs again.
  bool _preselectScheduled = false;

  /// Selects the newest viewable model AFTER the frame, never during `build`.
  ///
  /// Mutating the parent's state inside a build is the classic way to get a
  /// "setState during build" crash out of a provider that resolves
  /// synchronously (a cached list, an overridden provider in a test).
  void _schedulePreselect(List<ProjectModelView> models) {
    if (!widget.autoSelectNewest || _preselectScheduled) return;
    // The backend orders newest-first (`listProjectModels` sorts
    // `{ createdAt: -1 }`), so the FIRST viewable record is the newest one and
    // no client-side sort is needed — re-sorting here would only risk
    // disagreeing with the list the user is looking at.
    String? newest;
    for (final model in models) {
      if (model.isViewable) {
        newest = model.id;
        break;
      }
    }
    if (newest == null) return;
    final id = newest;

    _preselectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preselectScheduled = false;
      if (!mounted || widget.selectedModelId != null) return;
      widget.onModelChanged(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projectsAsync = ref.watch(projectsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        projectsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: AppLoadingIndicator(),
          ),
          error: (_, __) => const _PickerNote(
            'We could not load your captures. Pull to refresh on Projects, then '
            'come back.',
            color: AppColors.error,
          ),
          data: (projects) {
            // `modelCount` is the SERVER's count of SUCCEEDED models, so a
            // capture that is still building its first one is correctly absent:
            // it has nothing selectable, and offering it would only produce a
            // create the server then refuses. (A capture that IS offered can
            // still show a pending row below — that is a capture with a
            // finished model AND a regenerate in flight, which is a different
            // thing and reads as one.)
            final ready = projects.where((p) => p.hasViewableModels).toList();
            if (ready.isEmpty) {
              return const _PickerNote(
                'You have no finished 3D models yet. Capture something first, '
                'or add this product as a photo instead.',
              );
            }
            return DropdownButtonFormField<String>(
              key: const ValueKey('model_picker_capture_dropdown'),
              initialValue: ready.any((p) => p.id == widget.selectedProjectId)
                  ? widget.selectedProjectId
                  : null,
              isExpanded: true,
              dropdownColor: AppColors.surface2,
              decoration: const InputDecoration(
                hintText: 'Choose a finished capture',
              ),
              items: [
                for (final project in ready)
                  DropdownMenuItem(
                    value: project.id,
                    child: Text(
                      project.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: widget.enabled ? widget.onProjectChanged : null,
            );
          },
        ),
        if (widget.selectedProjectId case final projectId?) ...[
          const SizedBox(height: AppSpacing.lg),
          _ModelChoiceList(
            projectId: projectId,
            selectedModelId: widget.selectedModelId,
            currentModelId: widget.currentModelId,
            enabled: widget.enabled,
            onModelChanged: widget.onModelChanged,
            onPreview: widget.onPreview,
            onData: _schedulePreselect,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Text(
          "The model's files are copied onto the product, so regenerating it "
          'later will not change what customers see.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// The model list for ONE capture — every record it has, newest first.
class _ModelChoiceList extends ConsumerWidget {
  const _ModelChoiceList({
    required this.projectId,
    required this.selectedModelId,
    required this.currentModelId,
    required this.enabled,
    required this.onModelChanged,
    required this.onPreview,
    required this.onData,
  });

  final String projectId;
  final String? selectedModelId;
  final String? currentModelId;
  final bool enabled;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<ProjectModelView> onPreview;
  final ValueChanged<List<ProjectModelView>> onData;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(ownerModelHistoryProvider(projectId));

    return async.when(
      // A FIXED height, so the form does not jump under the user's finger the
      // moment the list lands.
      loading: () => const SizedBox(
        height: _kTileExtent,
        child: AppLoadingIndicator(),
      ),
      error: (error, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mapped owner-safe copy — never a raw DioException and never a code.
          _PickerNote(failureCopy(error), color: AppColors.error),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Retry',
            icon: Icons.refresh,
            isFullWidth: false,
            onPressed: () =>
                ref.invalidate(ownerModelHistoryProvider(projectId)),
          ),
        ],
      ),
      data: (models) {
        onData(models);
        final viewable = models.where((m) => m.isViewable).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose which model to use',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  // Counts what can actually be PICKED. The project list's
                  // `modelCount` counts SUCCEEDED records including the
                  // `optimized` copy, which is right for gating the dropdown
                  // but would read as a promise here.
                  viewable == 1 ? '1 available' : '$viewable available',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (models.isEmpty)
              const _PickerNote('This capture has no 3D model yet.')
            else ...[
              if (viewable == 0)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _PickerNote(
                    'This capture has no finished 3D model yet.',
                    color: AppColors.warning,
                  ),
                ),
              // The current model is gone (a purged record, a deleted project).
              // Said plainly, and nothing is silently re-picked in its place.
              if (currentModelId != null &&
                  !models.any((m) => m.id == currentModelId))
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _PickerNote(
                    "The model this product uses is no longer in this capture. "
                    'Pick another one to replace it.',
                    color: AppColors.warning,
                  ),
                ),
              _TileList(
                models: models,
                selectedModelId: selectedModelId,
                currentModelId: currentModelId,
                enabled: enabled,
                onModelChanged: onModelChanged,
                onPreview: onPreview,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Lays the tiles out for the viewport it actually has.
class _TileList extends StatelessWidget {
  const _TileList({
    required this.models,
    required this.selectedModelId,
    required this.currentModelId,
    required this.enabled,
    required this.onModelChanged,
    required this.onPreview,
  });

  final List<ProjectModelView> models;
  final String? selectedModelId;
  final String? currentModelId;
  final bool enabled;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<ProjectModelView> onPreview;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (final model in models)
        ModelChoiceTile(
          key: ValueKey('model_choice_tile_${model.id}'),
          model: model,
          selected: model.id == selectedModelId,
          isCurrent: model.id == currentModelId,
          enabled: enabled,
          onSelect: () => onModelChanged(model.id),
          onPreview: () => onPreview(model),
        ),
    ];

    // Short enough to inline: the tiles join the form's own scroll, which is
    // the behaviour a phone wants and the one a keyboard user on web expects
    // (tab order runs straight down the page).
    if (tiles.length <= kModelPickerInlineLimit) {
      return Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            tiles[i],
          ],
        ],
      );
    }

    // Long: a bounded panel that scrolls inside itself, so a capture with a
    // dozen regenerates does not push the name field ten screens down.
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: kModelPickerInlineLimit * _kTileExtent,
      ),
      child: Scrollbar(
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: tiles.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (_, index) => tiles[index],
        ),
      ),
    );
  }
}

class _PickerNote extends StatelessWidget {
  const _PickerNote(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: color ?? AppColors.textMuted, height: 1.4),
      );
}
