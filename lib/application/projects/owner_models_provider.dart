// lib/application/projects/owner_models_provider.dart
//
// Every finished model ONE project has, as its owner sees them — the data
// behind the owner-facing "Models" list.
//
// A plain [FutureProvider], not a notifier, because there is nothing to drive:
// this list only changes when a generation FINISHES, and the surfaces that
// watch a running generation already exist ([ownerModelStateProvider] polls
// `GET /projects/:id` for exactly that). Adding a second poll loop here would
// mean two timers asking two endpoints the same question. Refresh is a
// `ref.refresh` on pull-to-refresh, and returning from a regenerate.
//
// The STAFF equivalent is [modelGenerationProvider], which polls the admin
// history route an owner is forbidden from calling (403) — same shape of
// problem, different audience, different endpoint.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/projects_repository.dart';
import '../../domain/entities/project_model.dart';

/// A project's finished models, newest first. Empty means none have finished.
/// Auto-disposed with the screen that watches it.
final ownerModelsProvider =
    FutureProvider.autoDispose.family<List<ProjectModelView>, String>(
  (ref, projectId) => ref.watch(projectsRepositoryProvider).fetchModels(projectId),
);
