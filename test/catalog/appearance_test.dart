// test/catalog/appearance_test.dart
//
// The Appearance screen and its notifier (more-customization Stage 2):
//   • save writes the draft through the profile repository and adopts the row;
//   • reset sends null (the default page);
//   • an unreadable colour shows the warning and DISABLES Save — the API would
//     refuse it, and Mirage-fe would drop it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/appearance_notifier.dart';
import 'package:recapture/application/catalog/business_profile_notifier.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/repositories/business_profile_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/appearance.dart';
import 'package:recapture/domain/catalog/catalog_scope.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/screens/catalog/appearance_screen.dart';
import 'package:recapture/presentation/widgets/app_button.dart';

import 'business_profile_test.dart' show FakeBrandingRepository, FakeProfileRepository;
import 'catalog_entities_test.dart' as golden;

/// Records every appearance write.
class _AppearanceRepo implements BusinessProfileRepository {
  _AppearanceRepo(this.profile);

  BusinessProfile profile;
  final List<CatalogAppearance?> writes = [];

  @override
  Future<BusinessProfile?> fetch() async => profile;

  @override
  Future<BusinessProfile> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      throw UnimplementedError();

  @override
  Future<BusinessProfile> updateAppearance(CatalogAppearance? appearance) async {
    writes.add(appearance);
    profile = profile.withAppearance(appearance);
    return profile;
  }
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The real ConfigNotifier bootstraps from Hive and the network.
class _StubConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

List<Override> _overrides(_AppearanceRepo repo) => [
      authProvider.overrideWith(_StubAuth.new),
      captureConfigProvider.overrideWith(_StubConfig.new),
      businessProfileRepositoryProvider.overrideWithValue(repo),
      // Only its catalog read is touched — by the draft-badge refresh a save
      // triggers.
      catalogRepositoryProvider
          .overrideWithValue(FakeBrandingRepository(FakeProfileRepository())),
      // The preview's sample dishes are best-effort; an empty list draws the
      // placeholder dishes.
      appearanceSampleDishesProvider.overrideWith((ref, scope) async => []),
    ];

BusinessProfile _profile([Map<String, dynamic>? appearance]) =>
    BusinessProfile.fromMap({...golden.profileGolden(), 'appearance': appearance});

const owner = CatalogScope.owner();

void main() {
  group('AppearanceNotifier', () {
    Future<(ProviderContainer, _AppearanceRepo)> ready([Map<String, dynamic>? saved]) async {
      final repo = _AppearanceRepo(_profile(saved));
      final container = ProviderContainer(overrides: _overrides(repo));
      addTearDown(container.dispose);
      await container.read(businessProfileFor(owner).future);
      // Keep the autoDispose draft alive for the test.
      container.listen(appearanceFor(owner), (_, __) {});
      return (container, repo);
    }

    test('starts from the saved look, or Basalt, and is not dirty', () async {
      final (c, _) = await ready();
      expect(c.read(appearanceFor(owner)).draft.presetId, 'basalt');
      expect(c.read(appearanceFor(owner)).isDirty, isFalse);

      final (c2, _) = await ready({'presetId': 'royal'});
      expect(c2.read(appearanceFor(owner)).draft.presetId, 'royal');
    });

    test('save writes the draft and adopts the saved row', () async {
      final (c, repo) = await ready();
      final n = c.read(appearanceFor(owner).notifier);

      n.pickPreset('espresso');
      n.setAccent('#e6c79c');
      expect(c.read(appearanceFor(owner)).isDirty, isTrue);
      expect(await n.save(), isTrue);

      expect(repo.writes.single?.toMap(), {'presetId': 'espresso', 'accent': '#E6C79C'});
      expect(c.read(appearanceFor(owner)).isDirty, isFalse);
      expect(c.read(businessProfileFor(owner)).valueOrNull?.appearance?.presetId, 'espresso');
    });

    test('picking a preset drops colours chosen for the last one', () async {
      final (c, _) = await ready();
      final n = c.read(appearanceFor(owner).notifier);
      n.setPrimary('#1565C0');
      n.pickPreset('garden');
      expect(c.read(appearanceFor(owner)).draft.primary, isNull);
    });

    test('an unreadable colour cannot be saved', () async {
      final (c, repo) = await ready();
      final n = c.read(appearanceFor(owner).notifier);
      n.pickPreset('garden');
      n.setPrimary('#FFF59D');
      expect(n.canSave, isFalse);
      expect(await n.save(), isFalse);
      expect(repo.writes, isEmpty);
    });

    test('reset sends null — the default page', () async {
      final (c, repo) = await ready({'presetId': 'royal'});
      expect(await c.read(appearanceFor(owner).notifier).reset(), isTrue);
      expect(repo.writes, [null]);
      expect(c.read(appearanceFor(owner)).saved, isNull);
      expect(c.read(appearanceFor(owner)).draft.presetId, 'basalt');
    });
  });

  group('AppearanceScreen', () {
    Future<_AppearanceRepo> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _AppearanceRepo(_profile());
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(repo),
          child: const MaterialApp(home: AppearanceScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    Finder save() => find.byKey(const Key('appearance-save'));

    bool saveEnabled(WidgetTester tester) =>
        tester.widget<AppButton>(save()).onPressed != null;

    testWidgets('Save is off until something changes, then saves', (tester) async {
      final repo = await pump(tester);
      expect(saveEnabled(tester), isFalse);

      await tester.tap(find.byKey(const Key('appearance-preset-espresso')));
      await tester.pump();
      expect(saveEnabled(tester), isTrue);

      await tester.tap(save());
      await tester.pumpAndSettle();
      expect(repo.writes.single?.presetId, 'espresso');
    });

    testWidgets('an unreadable colour warns and disables Save', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('appearance-preset-garden')));
      await tester.pump();
      await tester.tap(find.text('Customize colours'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('appearance-hex-primary')), 'FFF59D');
      await tester.pump();

      expect(find.byKey(const Key('appearance-contrast-warning')), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });
  });
}
