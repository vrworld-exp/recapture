// lib/presentation/widgets/catalog/catalog_feedback.dart
//
// The ONE place a catalog surface says "that worked" or "that didn't".
//
// Every catalog screen routes its confirmations, undos and failures through
// here rather than calling `ScaffoldMessenger` with a hand-written string.
// Three reasons, in order of how badly the alternative goes:
//   • Without a confirmation, users repeat destructive actions — they archive
//     twice because the first one looked like nothing happened.
//   • Ad-hoc strings drift. "Product archived" here and "Archived!" there is
//     how one feature ends up reading like three.
//   • A failure sentence has a JOB: name the object, say why in plain language,
//     say what to do next. That is hard to remember at every call site and easy
//     to enforce in one.
//
// Everything takes a [ScaffoldMessengerState] rather than a [BuildContext],
// deliberately. A catalog action outlives the widget that started it — the
// editor archives a product and POPS, the undo fires six seconds later from a
// screen that is gone — and a context captured across that await is a crash or
// a silently dropped message. Capture the messenger first with
// [CatalogFeedback.of], then await.
import 'package:flutter/material.dart';

import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/catalog_error_copy.dart';

/// How long an undo stays on offer.
///
/// Long enough to notice and reach, short enough that it is not still sitting
/// there when the user has moved on. The undo is never the ONLY way back:
/// archiving is reversible from the Archived filter forever, which is what
/// makes six seconds an acceptable window rather than a deadline.
const Duration kCatalogUndoWindow = Duration(seconds: 6);

/// How long a plain confirmation stays.
const Duration kCatalogToastDuration = Duration(seconds: 4);

/// Width at or above which the snackbar stops spanning the whole window.
///
/// From the WINDOW width, not the platform: a floating snackbar stretched
/// across 1600 px puts its action button in the far corner, a screen's width
/// away from the card the user just acted on. Pinning it keeps the undo where
/// the eye already is. Same rule as everywhere else on this surface — layout
/// comes from measurement, never from `kIsWeb`.
const double kCatalogToastConstrainWidth = 720;

/// The width it is pinned to above that.
const double kCatalogToastWidth = 560;

/// Catalog-wide user feedback.
abstract final class CatalogFeedback {
  /// Captures the messenger while [context] is certainly mounted.
  ///
  /// Call this BEFORE the await, always. This is the whole reason the rest of
  /// the API does not take a context.
  static ScaffoldMessengerState of(BuildContext context) =>
      ScaffoldMessenger.of(context);

  /// "That worked." One sentence, no action.
  static void confirm(ScaffoldMessengerState messenger, String message) =>
      _show(messenger, message: message, duration: kCatalogToastDuration);

  /// "That worked — and you can take it back."
  ///
  /// [onUndo] must perform the REAL inverse (a restore call, not a local state
  /// flip). An undo that only repaints the grid tells the user the server
  /// agrees with them when it does not.
  static void undoable(
    ScaffoldMessengerState messenger,
    String message, {
    required VoidCallback onUndo,
    String label = 'Undo',
  }) =>
      _show(
        messenger,
        message: message,
        duration: kCatalogUndoWindow,
        action: SnackBarAction(label: label, onPressed: onUndo),
      );

  /// "That didn't work, and here is what to do."
  ///
  /// [subject] names the object and the attempt ("Chair 02 could not be
  /// archived") — a bare "Something went wrong" leaves the user unsure WHICH of
  /// the things they just did failed.
  ///
  /// ⚠ THE SENTENCE COMES FROM THE CODE, NEVER FROM [CatalogFailure.message].
  /// The backend's own message is owner-safe, but reading it here would leave
  /// exactly one path by which text nobody on this side wrote could reach a
  /// user — a proxy's error page, a stub, a server one deploy ahead. Mapping
  /// the code instead makes that structurally impossible, and buys copy that
  /// can name the object and say what to do next. See [catalogErrorCopy].
  static void failure(
    ScaffoldMessengerState messenger,
    CatalogFailure failure, {
    required String subject,
    VoidCallback? onRetry,
    String retryLabel = 'Retry',
  }) =>
      _show(
        messenger,
        message: failureText(failure, subject: subject),
        duration: kCatalogToastDuration,
        action: onRetry == null
            ? null
            : SnackBarAction(label: retryLabel, onPressed: onRetry),
      );

  /// The same mapped sentence, for a surface that shows its failure INLINE
  /// rather than as a toast — the editor's error banner, the add-product form.
  ///
  /// One function for both so the two never diverge: a message worth writing
  /// for a snackbar is the message the banner should carry.
  static String failureText(CatalogFailure failure, {String? subject}) =>
      catalogErrorSentence(failure.code, subject: subject);

  /// The mapped sentence for a bare [code], where the caller holds a code
  /// rather than a [CatalogFailure] — a notifier's stored error, a publish
  /// row's status.
  static String textForCode(String? code, {String? subject}) =>
      catalogErrorSentence(code, subject: subject);

  static void _show(
    ScaffoldMessengerState messenger, {
    required String message,
    required Duration duration,
    SnackBarAction? action,
  }) {
    // The newest message wins. `ScaffoldMessenger` queues by default, which for
    // two rapid actions means the second confirmation appears four seconds
    // after the thing it is confirming — by then it reads as a report about
    // something else, and three quick archives leave a pile the user reads none
    // of. Replacing keeps the toast about what just happened.
    //
    // The cost is a pending UNDO being retired early. Accepted, because undo is
    // never the only way back: an archived product is restorable from the
    // Archived filter for as long as it exists, and the one action with no way
    // back — permanent delete — is gated by a typed confirmation instead of a
    // snackbar.
    messenger.hideCurrentSnackBar();

    final width = MediaQuery.maybeSizeOf(messenger.context)?.width ?? 0;
    final pinned = width >= kCatalogToastConstrainWidth;

    messenger.showSnackBar(
      SnackBar(
        // Wraps rather than truncates: a failure sentence that ends in an
        // ellipsis has thrown away the half that says what to do.
        //
        // `liveRegion` is what makes the toast reach a screen reader at all. A
        // snackbar is painted into the overlay and takes no focus, so without
        // it the announcement never happens: on the web build this becomes an
        // `aria-live` region, on Android/iOS a TalkBack/VoiceOver
        // announcement. A confirmation nobody hears is the same as no
        // confirmation, which is the whole failure mode this file exists for.
        content: Semantics(
          liveRegion: true,
          container: true,
          child: Text(message),
        ),
        duration: duration,
        action: action,
        // A keyboard-reachable way out, and the reason it is not a `Dismissible`
        // swipe alone: swiping is the ONLY built-in dismissal, and there is no
        // swipe on a desktop browser. The close button is a real
        // `IconButton` in the traversal order, so Tab reaches it and Enter or
        // Space dismisses — which is also how the undo action is reached.
        showCloseIcon: true,
        // `width` and `margin` are mutually exclusive on a SnackBar, which is
        // why the narrow case passes neither and takes the theme's default.
        width: pinned ? kCatalogToastWidth : null,
        // Stated rather than inherited: `width` ASSERTS on a fixed-behaviour
        // snackbar, and the app theme's floating default is not something this
        // helper can assume when it is used from a screen under any other
        // theme (a widget test's bare MaterialApp, for one).
        behavior: pinned ? SnackBarBehavior.floating : null,
      ),
    );
  }
}
