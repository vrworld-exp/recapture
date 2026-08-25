// lib/domain/entities/confirm_kind.dart
//
// Pure Dart — what destructive action a confirmation covers. Lives in the domain
// layer so both the presentation modal (showDeleteConfirmation) and the
// application action handler (ReviewActionsController) can reference it without
// the application layer depending on presentation. Every kind presents a
// destructive-styled confirm with a safe-default Cancel — only the wording differs.
//
//   delete / retake — photo-count-driven (delete removes them; retake replaces
//                     the existing shot).
//   signOut         — NOT photo-driven: it tears the session down (tokens plus
//                     every local Hive box). The count is irrelevant, so its copy
//                     ignores it; callers pass 1.
//   removeAvatar    — NOT photo-driven either: it clears the account's profile
//                     picture (server-side, plus the stored object). Also
//                     count-ignoring; callers pass 1. Its copy makes the OUTCOME
//                     concrete ("Your initials will be shown instead") rather
//                     than claiming permanence — the user can always pick a new
//                     picture.
enum ConfirmKind { delete, retake, signOut, removeAvatar }
