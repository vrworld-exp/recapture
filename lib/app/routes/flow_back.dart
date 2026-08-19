// lib/app/routes/flow_back.dart
//
// BACK navigation for the guided flow. Flow navigation uses context.go(),
// which REPLACES the GoRouter page stack instead of stacking pages — so the
// system back key/gesture (and any canPop-guarded AppBar arrow) usually has
// nothing to pop: hardware back would exit the app from the middle of the
// flow, and the arrows would silently do nothing. A real page stack is not an
// option here (stacked capture screens would keep multiple native camera
// bindings alive), so BACK gets an explicit destination instead:
//
//   - [flowBackRouteFor]: the flow's static "previous screen" per location
//     (pure — unit-testable like levelBCompleteNextRoute).
//   - [navigateBack]: pop when a pushed route exists (e.g. retake capture,
//     review pushed from a complete screen), else go() to the mapped
//     previous screen.
//   - [FlowBackScope]: routes the system back key through [navigateBack] for
//     screens that have no PopScope of their own — applied at the ROUTER
//     (createAppRouter), never inside the screens, so screen widget tests
//     stay router-free. Screens WITH their own PopScope (capture's
//     Save & Exit, review's selection mode, summary/upload guards) keep their
//     handlers and call [navigateBack] themselves where appropriate.

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'app_router.dart';

/// The guided flow's "previous screen" for [location] — where BACK lands when
/// the Navigator has nothing to pop. Null = no mapping: BACK keeps the
/// platform default (on the projects/auth home screens that is leaving the
/// app, which is correct there). Deliberately ABSENT: the capture screens
/// (their Save & Exit flow owns back → projects) and the summary/upload
/// screens (their own PopScope guards own the decision).
String? flowBackRouteFor(String location) {
  // The Preview gallery path carries a concrete project id (`:id`), so it can't
  // be matched by the exact-string switch below — detect it by shape first.
  if (location.startsWith('/admin/projects/') &&
      location.endsWith('/preview')) {
    return AppRoutes.projects;
  }
  // Same shape problem: the change-model path carries a concrete product id.
  // Normally pushed (so this never fires); the mapping is for the cold
  // deep-link, where there is no catalog underneath to pop to.
  if (location.startsWith('/catalog/products/') &&
      location.endsWith('/model')) {
    return AppRoutes.catalog;
  }
  return switch (location) {
    AppRoutes.otpVerify => AppRoutes.auth,
    AppRoutes.createProject => AppRoutes.projects,
    AppRoutes.profile => AppRoutes.projects,
    // The catalog shell is a top-level destination reached with go() from
    // Projects, so it has nothing to pop — back lands on Projects rather than
    // exiting the app. Its sub-screens map back to the shell as they land.
    AppRoutes.catalog => AppRoutes.projects,
    // Normally pushed from the shell (so this never fires); the mapping is
    // for the cold deep-link, where there is no shell underneath to pop to.
    AppRoutes.productNew => AppRoutes.catalog,
    AppRoutes.preCapture => AppRoutes.projects,
    AppRoutes.permissions => AppRoutes.preCapture,
    AppRoutes.levelAIntro => AppRoutes.permissions,
    AppRoutes.levelAReview => AppRoutes.levelACapture,
    AppRoutes.levelAComplete => AppRoutes.levelAReview,
    AppRoutes.levelBIntro => AppRoutes.levelAComplete,
    AppRoutes.levelBReview => AppRoutes.levelBCapture,
    AppRoutes.levelBComplete => AppRoutes.levelBReview,
    AppRoutes.levelCIntro => AppRoutes.levelBComplete,
    AppRoutes.levelCReview => AppRoutes.levelCCapture,
    AppRoutes.levelCComplete => AppRoutes.levelCReview,
    AppRoutes.processing => AppRoutes.projects,
    AppRoutes.modelReady => AppRoutes.projects,
    AppRoutes.arPreview => AppRoutes.modelReady,
    _ => null,
  };
}

/// The one BACK behavior every back affordance (system key, AppBar arrow)
/// funnels through: pop a genuinely pushed route when one exists, else go()
/// to the flow's mapped previous screen. Safe outside a GoRouter (plain
/// MaterialApp widget tests): degrades to Navigator.maybePop.
void navigateBack(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    Navigator.maybePop(context);
    return;
  }
  if (router.canPop()) {
    router.pop();
    return;
  }
  final target = flowBackRouteFor(GoRouterState.of(context).matchedLocation);
  if (target != null) router.go(target);
}

/// Routes the system back key/gesture through [navigateBack]. Always
/// intercepts ([PopScope.canPop] false): with go()-replaced single-page
/// stacks, letting the pop "succeed" would exit the app mid-flow.
class FlowBackScope extends StatelessWidget {
  const FlowBackScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) navigateBack(context);
        },
        child: child,
      );
}
