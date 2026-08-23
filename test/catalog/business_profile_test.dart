// test/catalog/business_profile_test.dart
//
// The business profile (features 58, 59, 60, 2).
//
// What this file exists to catch, in order of how badly the alternative goes:
//   • The screen telling a business that a field is on their public page when
//     it is not. Reach is read PER FIELD from the server's `publicFields`, and
//     a test that only checked "some label is rendered" would pass while the
//     labels were the wrong way round.
//   • A failed COMMIT costing the user their upload a second time. The bytes are
//     already in the bucket; the retry must be the commit alone.
//   • A save that sends a partial contact block. The server REPLACES the block,
//     so a delta silently wipes every field it omits.
//
// Hermetic: both repositories and the image picker are faked. No HTTP, no Hive.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/business_profile_notifier.dart';
import 'package:recapture/data/datasources/product_image_picker.dart';
import 'package:recapture/data/repositories/business_profile_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/business_profile_validators.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/presentation/screens/catalog/business_profile_screen.dart';
import 'catalog_repo_publish_defaults.dart';

import 'catalog_entities_test.dart' as golden;

BusinessProfile profileFrom(Map<String, dynamic> map) =>
    BusinessProfile.fromMap(map);

/// One recorded PATCH.
class ProfilePatch {
  ProfilePatch(this.name, this.businessName, this.contact);

  final String? name;
  final String? businessName;
  final BusinessContact? contact;
}

class FakeProfileRepository implements BusinessProfileRepository {
  FakeProfileRepository({BusinessProfile? profile})
      : profile = profile ?? profileFrom(golden.profileGolden());

  BusinessProfile? profile;
  final List<ProfilePatch> patches = [];

  /// Set to fail the next update.
  CatalogFailure? updateFailure;

  @override
  Future<BusinessProfile?> fetch() async => profile;

  @override
  Future<BusinessProfile> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) async {
    patches.add(ProfilePatch(name, businessName, contact));
    if (updateFailure != null) throw updateFailure!;

    final updated = (profile ?? profileFrom(golden.profileGolden())).copyWith(
      name: name,
      businessName: businessName,
      contact: contact,
    );
    profile = updated;
    return updated;
  }
}

/// One recorded branding upload.
class BrandingUploadCall {
  BrandingUploadCall(this.slot, this.length, this.contentType);

  final BrandingSlot slot;
  final int length;
  final String contentType;
}

/// A catalog repository that serves the branding half of the flow.
class FakeBrandingRepository with CatalogRepoPublishDefaults implements CatalogRepository {
  FakeBrandingRepository(this.profileRepo);

  final FakeProfileRepository profileRepo;

  final List<BrandingUploadCall> uploads = [];
  final List<String> commits = [];

  /// Set to fail the next upload / commit. Cleared by the test to let a retry
  /// through.
  CatalogFailure? uploadFailure;
  CatalogFailure? commitFailure;

  int _keySeq = 0;

  @override
  Future<String> uploadBrandingBytes(
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) async {
    uploads.add(BrandingUploadCall(slot, bytes.length, contentType));
    if (uploadFailure != null) throw uploadFailure!;
    return 'test/catalog/c/products/${slot.apiValue}/${_keySeq++}.jpg';
  }

  @override
  Future<BusinessProfile> commitBranding({
    required BrandingSlot slot,
    required String key,
  }) async {
    commits.add(key);
    if (commitFailure != null) throw commitFailure!;

    final current = profileRepo.profile ?? profileFrom(golden.profileGolden());
    final updated = current.copyWith(
      logoUrl:
          slot == BrandingSlot.logo ? 'https://cdn.example.com/$key' : null,
      coverImageUrl:
          slot == BrandingSlot.cover ? 'https://cdn.example.com/$key' : null,
    );
    profileRepo.profile = updated;
    return updated;
  }

  @override
  Future<Catalog?> fetch() async => Catalog.fromMap(golden.catalogGolden());

  @override
  Future<CatalogCategoryList> listCategories() async =>
      CatalogCategoryList.empty;

  // ── Not used by these tests ───────────────────────────────────────────────

  @override
  Future<Catalog> create({required String name, String? businessName}) =>
      throw UnimplementedError();

  @override
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createBrandingSlot({
    required BrandingSlot slot,
    required ProductImageContentType contentType,
  }) =>
      throw UnimplementedError();

  @override
  Future<CatalogCategory> createCategory(String name) =>
      throw UnimplementedError();

  @override
  Future<CatalogCategory> renameCategory(String id, String name) =>
      throw UnimplementedError();

  @override
  Future<int> deleteCategory(String id) => throw UnimplementedError();

  @override
  Future<void> reorderCategories(List<String> orderedIds) =>
      throw UnimplementedError();
}

/// A picker that hands back fixed bytes without a platform channel.
class FakePicker implements ProductImagePicker {
  FakePicker({this.picked});

  PickedProductImage? picked;
  int calls = 0;

  @override
  Future<PickedProductImage?> pickProductImage() async {
    calls++;
    return picked;
  }
}

/// Auth held still — the notifier listens to it and the real one reaches for
/// secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

ProviderContainer containerWith(
  FakeProfileRepository profileRepo,
  FakeBrandingRepository brandingRepo, {
  ProductImagePicker? picker,
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      businessProfileRepositoryProvider.overrideWithValue(profileRepo),
      catalogRepositoryProvider.overrideWithValue(brandingRepo),
      if (picker != null) productImagePickerProvider.overrideWithValue(picker),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget harness(
  FakeProfileRepository profileRepo,
  FakeBrandingRepository brandingRepo, {
  double width = 500,
  ProductImagePicker? picker,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        businessProfileRepositoryProvider.overrideWithValue(profileRepo),
        catalogRepositoryProvider.overrideWithValue(brandingRepo),
        if (picker != null)
          productImagePickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp(
        home: Center(
          child: SizedBox(
            width: width,
            height: 800,
            child: const BusinessProfileScreen(),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validation bounds', () {
    test('the storefront name is required and bounded', () {
      expect(validateCatalogName('  '), isNotNull);
      expect(validateCatalogName('Cafe Mocha'), isNull);
      expect(
        validateCatalogName('x' * (kMaxCatalogNameLength + 1)),
        isNotNull,
      );
      expect(validateCatalogName('x' * kMaxCatalogNameLength), isNull);
    });

    test('every optional field is bounded at the backend Zod maximum', () {
      expect(validatePhone('x' * kMaxContactPhoneLength), isNull);
      expect(validatePhone('x' * (kMaxContactPhoneLength + 1)), isNotNull);

      expect(validateAddress('x' * kMaxContactAddressLength), isNull);
      expect(validateAddress('x' * (kMaxContactAddressLength + 1)), isNotNull);

      expect(validateSocial('x' * kMaxSocialLinkLength, 'Instagram'), isNull);
      expect(
        validateSocial('x' * (kMaxSocialLinkLength + 1), 'Instagram'),
        isNotNull,
      );

      expect(validateWhatsapp('x' * kMaxWhatsappLength), isNull);
      expect(validateWhatsapp('x' * (kMaxWhatsappLength + 1)), isNotNull);
    });

    test('an empty optional field is valid — clearing one is legitimate', () {
      expect(validatePhone(''), isNull);
      expect(validateEmail('   '), isNull);
      expect(validateWebsite(null), isNull);
      expect(validateBusinessName(''), isNull);
    });

    test('email is shape-checked, loosely', () {
      expect(validateEmail('hello@shop.example'), isNull);
      expect(validateEmail('hello'), isNotNull);
      expect(validateEmail('hello@shop'), isNotNull);
      expect(
        validateEmail('${'x' * kMaxContactEmailLength}@a.b'),
        isNotNull,
      );
    });

    test('a website without a scheme gets one, and keeps one it has', () {
      expect(normalizeWebsite('mystore.in'), 'https://mystore.in');
      expect(normalizeWebsite('http://mystore.in'), 'http://mystore.in');
      expect(normalizeWebsite('https://mystore.in'), 'https://mystore.in');
      // Not host-shaped — a scheme here would be a worse lie than the text.
      expect(normalizeWebsite('coming soon'), 'coming soon');
      expect(normalizeWebsite('   '), isNull);
    });

    test('the website bound is checked on the value that will be STORED', () {
      // 199 characters of host normalise to 207 with `https://` in front. A
      // form that accepted this would be accepting a value the save rejects.
      final host = '${'x' * 190}.example';
      expect(host.length, lessThan(kMaxContactWebsiteLength));
      expect(normalizeWebsite(host)!.length,
          greaterThan(kMaxContactWebsiteLength));
      expect(validateWebsite(host), isNotNull);
    });

    test('display strips the scheme it stores', () {
      expect(displayWebsite('https://mystore.in/'), 'mystore.in');
      expect(displayWebsite('http://mystore.in'), 'mystore.in');
    });
  });

  group('save', () {
    test('sends the WHOLE contact block, not a delta', () async {
      final profileRepo = FakeProfileRepository();
      final container =
          containerWith(profileRepo, FakeBrandingRepository(profileRepo));

      await container.read(businessProfileProvider.future);
      await container.read(businessProfileProvider.notifier).save(
            name: 'Cafe Mocha',
            businessName: 'Mocha Foods Pvt Ltd',
            contact: const BusinessContact(phone: '+91 1', address: 'Pune'),
          );

      final patch = profileRepo.patches.single;
      expect(patch.contact, isNotNull);
      // The server REPLACES the block, so the fields the form left empty must
      // arrive as absent — that is what clears them.
      expect(patch.contact!.email, isNull);
      expect(patch.contact!.website, isNull);
      expect(patch.contact!.socials, isNull);
      expect(patch.contact!.phone, '+91 1');
    });

    test('the profile re-renders from the server response', () async {
      final profileRepo = FakeProfileRepository();
      final container =
          containerWith(profileRepo, FakeBrandingRepository(profileRepo));

      await container.read(businessProfileProvider.future);
      await container.read(businessProfileProvider.notifier).save(
            name: 'New Name',
            contact: const BusinessContact(phone: '+91 2'),
          );

      final state = container.read(businessProfileProvider).valueOrNull;
      expect(state!.name, 'New Name');
      expect(state.contact!.phone, '+91 2');
    });

    test('a failed save throws and leaves the profile on screen', () async {
      final profileRepo = FakeProfileRepository()
        ..updateFailure = const CatalogFailure(
          code: 'INVALID_REQUEST',
          message: 'That name is too long.',
        );
      final container =
          containerWith(profileRepo, FakeBrandingRepository(profileRepo));

      await container.read(businessProfileProvider.future);

      await expectLater(
        container.read(businessProfileProvider.notifier).save(
              name: 'x',
              contact: const BusinessContact(),
            ),
        throwsA(isA<CatalogFailure>()),
      );
      expect(container.read(businessProfileProvider).valueOrNull, isNotNull);
    });
  });

  group('branding upload', () {
    Uint8List bytes(int n) => Uint8List.fromList(List<int>.filled(n, 1));

    test('uploads once, then commits', () async {
      final profileRepo = FakeProfileRepository();
      final brandingRepo = FakeBrandingRepository(profileRepo);
      final container = containerWith(profileRepo, brandingRepo);

      await container.read(businessProfileProvider.future);
      final ok =
          await container.read(businessProfileProvider.notifier).uploadBranding(
                BrandingSlot.logo,
                bytes(12),
                contentType: 'image/jpeg',
              );

      expect(ok, isTrue);
      expect(brandingRepo.uploads, hasLength(1));
      expect(brandingRepo.uploads.single.slot, BrandingSlot.logo);
      expect(brandingRepo.commits, hasLength(1));
      expect(
        container.read(businessProfileProvider).valueOrNull!.logoUrl,
        contains('logo'),
      );
    });

    test(
      'a failed commit retries the COMMIT — the bytes are not sent again',
      () async {
        final profileRepo = FakeProfileRepository();
        final brandingRepo = FakeBrandingRepository(profileRepo)
          ..commitFailure = const CatalogFailure(
            code: 'OBJECT_NOT_FOUND',
            message: 'Upload the image before saving it.',
          );
        final container = containerWith(profileRepo, brandingRepo);
        final notifier = container.read(businessProfileProvider.notifier);

        await container.read(businessProfileProvider.future);
        final first = await notifier.uploadBranding(
          BrandingSlot.logo,
          bytes(12),
          contentType: 'image/jpeg',
        );

        expect(first, isFalse);
        final pending = notifier.uploadOf(BrandingSlot.logo).value;
        expect(pending.canRetryCommit, isTrue,
            reason: 'the key must survive a failed commit');
        expect(pending.error, isNotNull);

        brandingRepo.commitFailure = null;
        final second = await notifier.retryCommit(BrandingSlot.logo);

        expect(second, isTrue);
        expect(brandingRepo.uploads, hasLength(1),
            reason: 'the retry must not re-upload');
        expect(brandingRepo.commits, hasLength(2));
        expect(brandingRepo.commits.first, brandingRepo.commits.last);
        expect(
          notifier.uploadOf(BrandingSlot.logo).value.canRetryCommit,
          isFalse,
          reason: 'nothing is left to retry once the pointer has flipped',
        );
      },
    );

    test('a failed UPLOAD leaves nothing to commit', () async {
      final profileRepo = FakeProfileRepository();
      final brandingRepo = FakeBrandingRepository(profileRepo)
        ..uploadFailure = const CatalogFailure(
          code: 'PAYLOAD_TOO_LARGE',
          message: 'That image is too large. Please choose a smaller one.',
        );
      final container = containerWith(profileRepo, brandingRepo);
      final notifier = container.read(businessProfileProvider.notifier);

      await container.read(businessProfileProvider.future);
      final ok = await notifier.uploadBranding(
        BrandingSlot.cover,
        bytes(9),
        contentType: 'image/png',
      );

      expect(ok, isFalse);
      expect(brandingRepo.commits, isEmpty);
      final upload = notifier.uploadOf(BrandingSlot.cover).value;
      expect(upload.canRetryCommit, isFalse);
      expect(upload.error!.message, contains('too large'));
    });
  });

  group('the screen', () {
    testWidgets('marks reach per field, from the server list', (tester) async {
      final profileRepo = FakeProfileRepository();
      await tester.pumpWidget(harness(
        profileRepo,
        FakeBrandingRepository(profileRepo),
      ));
      await tester.pumpAndSettle();

      // `publicFields` in the golden holds name / phone / address / logo. Every
      // other field must carry the OTHER sentence — this is the assertion that
      // catches the labels being the wrong way round.
      final public = find.text('Shown on your public page after you publish.');
      final private =
          find.text('Saved in ReCapture. Not shown on your public page yet.');

      expect(public, findsNWidgets(4));
      // businessName, email, website, 3 socials, whatsapp, cover.
      expect(private, findsNWidgets(8));
    });

    testWidgets('Save is disabled until something changes', (tester) async {
      final profileRepo = FakeProfileRepository();
      await tester.pumpWidget(harness(
        profileRepo,
        FakeBrandingRepository(profileRepo),
      ));
      await tester.pumpAndSettle();

      final save = find.widgetWithText(ElevatedButton, 'Save profile');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone (optional)'),
        '+91 99999 00000',
      );
      await tester.pump();

      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);
    });

    testWidgets('editing marks the form dirty for the router guard',
        (tester) async {
      final profileRepo = FakeProfileRepository();
      await tester.pumpWidget(harness(
        profileRepo,
        FakeBrandingRepository(profileRepo),
      ));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(BusinessProfileScreen)),
      );
      expect(container.read(businessProfileDirtyProvider), isFalse);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email (optional)'),
        'hi@shop.example',
      );
      await tester.pump();

      expect(container.read(businessProfileDirtyProvider), isTrue);
    });

    testWidgets('a save clears the dirty flag and the Save button',
        (tester) async {
      final profileRepo = FakeProfileRepository();
      await tester.pumpWidget(harness(
        profileRepo,
        FakeBrandingRepository(profileRepo),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Website (optional)'),
        'mystore.in',
      );
      await tester.pump();

      // The form is taller than the viewport — scroll the button into view
      // rather than tapping at a coordinate nothing is at.
      final save = find.widgetWithText(ElevatedButton, 'Save profile');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      // Normalised on the way out — a bare host in an href resolves against the
      // public page's own origin.
      expect(profileRepo.patches.single.contact!.website, 'https://mystore.in');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(BusinessProfileScreen)),
      );
      expect(container.read(businessProfileDirtyProvider), isFalse);
      expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Save profile'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('the Upload button drives the bytes path, not a File',
        (tester) async {
      final profileRepo = FakeProfileRepository();
      final brandingRepo = FakeBrandingRepository(profileRepo);
      final picker = FakePicker(
        picked: PickedProductImage(
          bytes: Uint8List.fromList(List<int>.filled(64, 7)),
          contentType: 'image/png',
        ),
      );

      await tester.pumpWidget(
        harness(profileRepo, brandingRepo, picker: picker),
      );
      await tester.pumpAndSettle();

      // The golden has a logo already, so the logo slot says Replace and the
      // cover slot — which has none — is the one offering an upload.
      final upload = find.widgetWithText(OutlinedButton, 'Upload Cover image');
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(brandingRepo.uploads, hasLength(1));
      expect(brandingRepo.uploads.single.slot, BrandingSlot.cover);
      expect(brandingRepo.uploads.single.contentType, 'image/png');
      expect(brandingRepo.uploads.single.length, 64);
      expect(brandingRepo.commits, hasLength(1));
    });

    testWidgets('no catalog yet is a first-run state, not an error',
        (tester) async {
      final profileRepo = FakeProfileRepository()..profile = null;
      await tester.pumpWidget(harness(
        profileRepo,
        FakeBrandingRepository(profileRepo),
      ));
      await tester.pumpAndSettle();

      expect(find.text('No catalog yet'), findsOneWidget);
      expect(find.byType(Form), findsNothing);
    });
  });
}
