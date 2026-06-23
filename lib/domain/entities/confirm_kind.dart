// lib/domain/entities/confirm_kind.dart
//
// Pure Dart — what destructive action a confirmation covers. Lives in the domain
// layer so both the presentation modal (showDeleteConfirmation) and the
// application action handler (ReviewActionsController) can reference it without
// the application layer depending on presentation. Both kinds DISCARD photos
// (delete removes them; retake replaces the existing shot), so both present a
// destructive-styled confirm with a safe-default Cancel — only the wording differs.
enum ConfirmKind { delete, retake }
