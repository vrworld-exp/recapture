// test/auth/rep_role_gating_test.dart
//
// Stage 6: who reaches `/rep`, and who is turned away before a screen renders.
//
// THE ASSERTION THAT MATTERS IS THE NEGATIVE ONE. A `USER` deep-linking to
// `/rep/catalogs/<someone else's id>` must be redirected by the ROUTER, not
// answered by a screen that renders, fires a request and shows a 403. The
// second is what a user reads as a broken app, and it is also the version that
// makes the surface discoverable to someone who should not know it exists.
//
// The gate is rank-based and inclusive upward, mirroring the backend — so
// MODEL_ARTIST and ADMIN pass it too. That is accepted rather than overlooked
// (both are script-granted, and every acting-on-behalf-of write leaves a
// delegation row), and it is pinned here so it stays a decision instead of
// becoming a surprise to whoever reads the ladder next.
//
// Driven through the REAL `repRedirectFor` the router calls, not a restatement
// of the rule — a test that re-implemented the gate would keep passing after
// the router stopped applying it.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/domain/entities/user_role.dart';

/// The gate as the router applies it, for one role and one location.
String? _redirect(UserRole role, String location) =>
    repRedirectFor(location, canUseRepSurface: role.isSalesRep);

/// Every rep destination, including the one with an id in it.
const _repLocations = [
  '/rep',
  AppRoutes.repCatalogs,
  AppRoutes.repActivate,
  '/rep/catalogs/6a9acad224584032c410c5c8',
];

void main() {
  group('the role ladder behind the gate', () {
    test('a USER is not a rep, and a rep is not staff', () {
      expect(UserRole.user.isSalesRep, isFalse);
      expect(UserRole.salesRep.isSalesRep, isTrue);
      // A rep has act-on-behalf-of writes and NO staff screens, so the Live
      // projects tab stays hidden for it — showing it would hand a rep a
      // surface that answers 403.
      expect(UserRole.salesRep.isStaff, isFalse);
      expect(UserRole.modelArtist.isStaff, isTrue);
    });

    test('the inheritance from the backend is inclusive upward', () {
      // Accepted, not overlooked. Pinned so a later reader finds a test rather
      // than a rank table to interpret.
      expect(UserRole.modelArtist.isSalesRep, isTrue);
      expect(UserRole.admin.isSalesRep, isTrue);
    });

    test('an unrecognised role fails CLOSED', () {
      // A failed /auth/me, or a server one deploy ahead, must not open /rep.
      expect(UserRole.fromApiValue(null).isSalesRep, isFalse);
      expect(UserRole.fromApiValue('SUPER_ADMIN').isSalesRep, isFalse);
    });
  });

  group('the redirect', () {
    test('sends a USER away from EVERY rep location', () {
      for (final location in _repLocations) {
        expect(
          _redirect(UserRole.user, location),
          AppRoutes.projects,
          reason: '$location must be gated for a plain USER',
        );
      }
    });

    test('sends them to their own hub, never to an error page', () {
      // A surface you do not have should be invisible, not broken.
      expect(_redirect(UserRole.user, AppRoutes.repCatalogs), AppRoutes.projects);
    });

    test('lets a SALES_REP through to every rep location', () {
      for (final location in _repLocations) {
        expect(
          _redirect(UserRole.salesRep, location),
          isNull,
          reason: '$location must be reachable by a SALES_REP',
        );
      }
    });

    test('lets a MODEL_ARTIST and an ADMIN through too', () {
      for (final role in [UserRole.modelArtist, UserRole.admin]) {
        for (final location in _repLocations) {
          expect(_redirect(role, location), isNull);
        }
      }
    });

    test('leaves every non-rep route alone, for every role', () {
      const elsewhere = [
        AppRoutes.projects,
        AppRoutes.catalog,
        AppRoutes.profile,
        AppRoutes.catalogQr,
        AppRoutes.preCapture,
      ];
      for (final role in UserRole.values) {
        for (final location in elsewhere) {
          expect(
            _redirect(role, location),
            isNull,
            reason: '$location is not a rep route and must not be gated',
          );
        }
      }
    });

    test('does not gate a route that merely STARTS with the letters', () {
      // `/reports` is not `/rep`. A `startsWith('/rep')` without the separator
      // would silently gate a future route on a substring.
      expect(_redirect(UserRole.user, '/reports'), isNull);
      expect(_redirect(UserRole.user, '/replay'), isNull);
    });
  });
}
