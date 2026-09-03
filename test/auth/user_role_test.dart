// test/auth/user_role_test.dart
//
// The role ladder itself: declaration order IS the ladder, so the rank getters
// (isStaff/isSalesRep) are asserted member by member. The load-bearing
// assertion is `salesRep.isStaff == false` — a rep has act-on-behalf-of writes
// and NO staff surfaces, and the previous `!= user` definition would have
// silently handed it the Live projects tab (a screen that answers 403).
// Pure domain, no widgets and no providers.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/user_role.dart';

void main() {
  group('UserRole ladder order', () {
    test('members are declared in ascending privilege order', () {
      expect(UserRole.values, [
        UserRole.user,
        UserRole.salesRep,
        UserRole.modelArtist,
        UserRole.admin,
      ]);
    });
  });

  group('isStaff', () {
    test('salesRep is NOT staff', () {
      expect(UserRole.salesRep.isStaff, isFalse);
    });

    test('user is not staff (fail-closed default)', () {
      expect(UserRole.user.isStaff, isFalse);
    });

    test('modelArtist and admin are staff', () {
      expect(UserRole.modelArtist.isStaff, isTrue);
      expect(UserRole.admin.isStaff, isTrue);
    });
  });

  group('isSalesRep', () {
    test('inclusive upward: salesRep, modelArtist and admin all pass', () {
      expect(UserRole.salesRep.isSalesRep, isTrue);
      expect(UserRole.modelArtist.isSalesRep, isTrue);
      expect(UserRole.admin.isSalesRep, isTrue);
    });

    test('user does not pass', () {
      expect(UserRole.user.isSalesRep, isFalse);
    });
  });

  group('isAdmin', () {
    test('only admin', () {
      expect(UserRole.admin.isAdmin, isTrue);
      for (final role in UserRole.values.where((r) => r != UserRole.admin)) {
        expect(role.isAdmin, isFalse, reason: '${role.name} must not be admin');
      }
    });
  });

  group('wire values', () {
    test('SALES_REP round-trips', () {
      expect(UserRole.fromApiValue('SALES_REP'), UserRole.salesRep);
      expect(UserRole.salesRep.apiValue, 'SALES_REP');
    });

    test('every member round-trips through fromApiValue', () {
      // A future member added without a wire mapping fails HERE, not in
      // production.
      for (final role in UserRole.values) {
        expect(
          UserRole.fromApiValue(role.apiValue),
          role,
          reason: '${role.name} does not survive apiValue -> fromApiValue',
        );
      }
    });

    test('an unrecognized value and null both fail closed to user', () {
      expect(UserRole.fromApiValue('WHATEVER'), UserRole.user);
      expect(UserRole.fromApiValue(null), UserRole.user);
    });
  });
}
