// test/admin/admin_standee_gating_test.dart
//
// Who reaches `/admin/standees`, and — the assertion that actually matters —
// who is NOT locked out by it.
//
// The standee gate is ADMIN-only, which is a stricter rule than anything else
// in the router. That makes its dangerous failure mode the opposite of the rep
// gate's: not "a USER got in" but "the gate was written as `/admin` and quietly
// revoked every MODEL_ARTIST's own staff screens". `/admin/projects/...`
// predates this feature and belongs to a lower role, so it is pinned here.
//
// Driven through the REAL `adminStandeesRedirectFor` the router calls, never a
// restatement of the rule — a test that re-implemented the gate would keep
// passing after the router stopped applying it.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/domain/entities/user_role.dart';

/// The gate as the router applies it, for one role and one location.
String? _redirect(UserRole role, String location) =>
    adminStandeesRedirectFor(location, canUseStandees: role.isAdmin);

/// Every standee destination, including the one with an id in it.
const _standeeLocations = [
  AppRoutes.adminStandees,
  '/admin/standees/6a9acad224584032c410c5c8',
];

/// Staff surfaces that live under `/admin` and are NOT this feature's.
const _staffProjectLocations = [
  '/admin/projects/6a9acad224584032c410c5c8/preview',
  '/admin/projects/6a9acad224584032c410c5c8/models',
];

void main() {
  group('the role behind the gate', () {
    test('isAdmin is exact, not a rank comparison', () {
      // Unlike isStaff and isSalesRep, this one does not inherit downward from
      // anything — ADMIN is the top of the ladder and the only holder.
      expect(UserRole.admin.isAdmin, isTrue);
      expect(UserRole.modelArtist.isAdmin, isFalse);
      expect(UserRole.salesRep.isAdmin, isFalse);
      expect(UserRole.user.isAdmin, isFalse);
    });

    test('an unrecognised role fails CLOSED', () {
      // Rolling the backend ahead of the client must not open this door.
      expect(UserRole.fromApiValue('SUPERUSER').isAdmin, isFalse);
      expect(UserRole.fromApiValue(null).isAdmin, isFalse);
    });
  });

  group('the standee subtree', () {
    test('an ADMIN is allowed through every destination', () {
      for (final location in _standeeLocations) {
        expect(_redirect(UserRole.admin, location), isNull, reason: location);
      }
    });

    test('every lesser role is redirected to its own hub, not to an error', () {
      for (final role in [
        UserRole.user,
        UserRole.salesRep,
        UserRole.modelArtist,
      ]) {
        for (final location in _standeeLocations) {
          expect(
            _redirect(role, location),
            AppRoutes.projects,
            reason: '$role at $location',
          );
        }
      }
    });

    test('the subtree test is a PREFIX, so an id route cannot slip past', () {
      // The batch-detail route is where a non-admin would actually reach
      // inventory, so a gate written as a set of literal paths would let
      // through exactly the one destination that carries data.
      expect(
        _redirect(UserRole.modelArtist, '/admin/standees/anything/deeper'),
        AppRoutes.projects,
      );
    });
  });

  group('what the gate must NOT catch', () {
    test('a MODEL_ARTIST keeps the staff project screens under /admin', () {
      // THE REGRESSION THIS FILE EXISTS FOR. Gating the whole `/admin` prefix on
      // ADMIN would pass every test above and silently revoke a staff role's own
      // surfaces — a failure that shows up as "the app is broken for staff",
      // with nothing pointing at the standee feature that caused it.
      for (final location in _staffProjectLocations) {
        expect(
          _redirect(UserRole.modelArtist, location),
          isNull,
          reason: location,
        );
      }
    });

    test('unrelated routes are untouched', () {
      for (final location in [AppRoutes.projects, AppRoutes.profile, '/rep']) {
        expect(_redirect(UserRole.user, location), isNull, reason: location);
      }
    });

    test('a prefix that merely starts the same way is not the subtree', () {
      // `/admin/standeesomething` is not `/admin/standees/...`.
      expect(_redirect(UserRole.user, '/admin/standeesomething'), isNull);
    });
  });
}
