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
//
// AT THE TOP OF THE SCREEN, NOT THE BOTTOM. The toast was a `SnackBar` until
// it was not: a snackbar is anchored to the bottom of the scaffold, and on the
// rep's dish editor and the owner's product editor that put "Dish saved" under
// the save button and the FAB, in the one strip of the screen a thumb is
// already covering — and, pinned to 560 px on a laptop, floating in the
// middle of the bottom edge where nothing else is. A `MaterialBanner` is the
// same messenger's other feature, laid out directly under the app bar, and
// with a non-zero elevation the scaffold FLOATS it over the body instead of
// pushing the body down (see `_ScaffoldLayout`), so nothing on the page jumps
// when it arrives. Everything the snackbar guaranteed is kept and tested:
// newest-wins, a live region, a keyboard-reachable close, wrapping, the
// laptop pin. The one thing a banner does not do on its own is leave, which
// is what [_AutoHide] is for.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
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

/// Width at or above which the toast stops spanning the whole window.
///
/// From the WINDOW width, not the platform: a banner stretched across 1600 px
/// puts its action button in the far corner, a screen's width away from the
/// card the user just acted on. Pinning it keeps the undo where the eye
/// already is. Same rule as everywhere else on this surface — layout comes
/// from measurement, never from `kIsWeb`.
const double kCatalogToastConstrainWidth = 720;

/// The width it is pinned to above that.
const double kCatalogToastWidth = 560;

/// The gap between the toast and the window's edge below the pin width.
const double kCatalogToastMargin = AppSpacing.md;

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
        action: (label: label, onPressed: onUndo),
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
        action:
            onRetry == null ? null : (label: retryLabel, onPressed: onRetry),
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
    ({String label, VoidCallback onPressed})? action,
  }) {
    // The newest message wins. `ScaffoldMessenger` queues by default, which for
    // two rapid actions means the second confirmation appears four seconds
    // after the thing it is confirming — by then it reads as a report about
    // something else, and three quick archives leave a pile the user reads none
    // of. Clearing keeps the toast about what just happened: the one on screen
    // animates out, anything still queued behind it is dropped.
    //
    // The cost is a pending UNDO being retired early. Accepted, because undo is
    // never the only way back: an archived product is restorable from the
    // Archived filter for as long as it exists, and the one action with no way
    // back — permanent delete — is gated by a typed confirmation instead of a
    // toast.
    messenger.clearMaterialBanners();

    // The pin is a MARGIN here — a banner has no `width` — computed from the
    // window the messenger lives in, which on every screen in this app is the
    // scaffold's width too.
    final width = MediaQuery.maybeSizeOf(messenger.context)?.width ?? 0;
    final pinned = width >= kCatalogToastConstrainWidth;
    final side =
        pinned ? (width - kCatalogToastWidth) / 2 : kCatalogToastMargin;

    messenger.showMaterialBanner(
      MaterialBanner(
        // Wraps rather than truncates: a failure sentence that ends in an
        // ellipsis has thrown away the half that says what to do.
        //
        // `liveRegion` is what makes the toast reach a screen reader at all. A
        // banner takes no focus, so without it the announcement never happens:
        // on the web build this becomes an `aria-live` region, on Android/iOS
        // a TalkBack/VoiceOver announcement. A confirmation nobody hears is
        // the same as no confirmation, which is the whole failure mode this
        // file exists for.
        content: _AutoHide(
          after: duration,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Text(message),
          ),
        ),
        // ONE action widget, so the banner lays it out beside the text rather
        // than on a second row underneath — two entries in this list is what
        // flips a `MaterialBanner` into its stacked layout.
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (action != null)
                TextButton(
                  // Taken down BEFORE the inverse runs: the inverse's own
                  // confirmation may arrive synchronously, and it must not be
                  // the banner this hide catches.
                  onPressed: () {
                    messenger.hideCurrentMaterialBanner(
                      reason: MaterialBannerClosedReason.dismiss,
                    );
                    action.onPressed();
                  },
                  child: Text(action.label),
                ),
              // A keyboard-reachable way out. A banner has no swipe to
              // dismiss at all, and there would be no swipe on a desktop
              // browser anyway. The close button is a real `IconButton` in the
              // traversal order, so Tab reaches it and Enter or Space
              // dismisses — which is also how the undo action is reached.
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: MaterialLocalizations.of(messenger.context)
                    .closeButtonTooltip,
                color: AppColors.textSecondary,
                onPressed: () => messenger.hideCurrentMaterialBanner(
                  reason: MaterialBannerClosedReason.dismiss,
                ),
              ),
            ],
          ),
        ],
        // Stated rather than inherited, and NON-ZERO on purpose: an elevation
        // of 0 is what makes the scaffold push the body down under the banner.
        // The look is the snackbar's — the app theme styles snackbars, not
        // banners, and a toast that changed colour when it moved would read
        // as a different kind of message.
        elevation: AppElevation.e2,
        backgroundColor: AppColors.surface2,
        contentTextStyle: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: AppTypography.sizeBody,
        ),
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.lg,
          top: AppSpacing.xs,
          bottom: AppSpacing.xs,
        ),
        margin: EdgeInsets.fromLTRB(side, AppSpacing.sm, side, 0),
      ),
    );
  }
}

/// Takes the banner down after [after], and only while it is the one showing.
///
/// A banner, unlike a snackbar, stays until something removes it. The timer
/// lives in a widget INSIDE the banner rather than in a static, so its life is
/// the banner's: replaced by a newer toast, closed by hand, or torn down with
/// the screen, the widget is disposed and the timer dies with it — a static
/// timer would fire later into whatever banner was current by then, and would
/// leak past the end of a widget test.
class _AutoHide extends StatefulWidget {
  const _AutoHide({required this.after, required this.child});

  final Duration after;
  final Widget child;

  @override
  State<_AutoHide> createState() => _AutoHideState();
}

class _AutoHideState extends State<_AutoHide> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.after, () {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .hideCurrentMaterialBanner(reason: MaterialBannerClosedReason.hide);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
