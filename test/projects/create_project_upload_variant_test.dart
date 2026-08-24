// test/projects/create_project_upload_variant_test.dart
//
// The Create Project form branches on the sheet's ProjectCreationChoice.
//
// The two claims worth pinning are exactly the ones the product owner and
// design doc 08 disagreed about:
//   • an UploadChoice renders NO OBJECT SIZE and NO CAPTURE MODE section (they
//     are capture concepts, and a placeholder MEDIUM/GUIDED would be a lie
//     later reads act on), and its CTA reads "Upload …";
//   • a CaptureChoice renders exactly what it always did.
//
// CATEGORY is pinned ABSENT on both variants: it was dropped from the upload
// form, and the field returning would be a silent regression here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/data/datasources/project_photo_picker.dart';
import 'package:recapture/domain/capture/capture_mode.dart' as capture_flow;
import 'package:recapture/presentation/screens/projects/capture_mode_sheet.dart';
import 'package:recapture/presentation/screens/projects/create_project_screen.dart';
import 'package:recapture/presentation/widgets/app_button.dart';

/// Hands the screen a fixed pick without a platform channel.
class _StubPicker implements ProjectPhotoPicker {
  _StubPicker(this.count);
  final int count;

  @override
  Future<PickedPhotoSet> pickPhotos({int alreadyPicked = 0}) async => PickedPhotoSet(
        accepted: List.generate(
          count,
          (i) => PickedProjectPhoto(
            name: 'photo_$i.jpg',
            path: '/photo_$i.jpg',
            size: 1000,
            contentType: 'image/jpeg',
          ),
        ),
        rejected: const [],
      );
}

Future<void> _pump(
  WidgetTester tester,
  ProjectCreationChoice choice, {
  ProjectPhotoPicker? picker,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (picker != null) projectPhotoPickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp(home: CreateProjectScreen(choice: choice)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('capture variant (unchanged)', () {
    testWidgets('renders OBJECT SIZE, CAPTURE MODE and the original CTA',
        (tester) async {
      await _pump(tester, const CaptureChoice(capture_flow.CaptureMode.full));

      expect(find.text('OBJECT SIZE'), findsOneWidget);
      expect(find.text('CAPTURE MODE'), findsOneWidget);
      expect(find.text('PHOTOS'), findsNothing);
      expect(find.text('CATEGORY'), findsNothing);
      expect(find.text('Create & Continue'), findsOneWidget);
    });
  });

  group('upload variant', () {
    testWidgets('hides OBJECT SIZE, CAPTURE MODE and CATEGORY; shows PHOTOS',
        (tester) async {
      await _pump(tester, const UploadChoice());

      expect(find.text('OBJECT SIZE'), findsNothing);
      expect(find.text('CAPTURE MODE'), findsNothing);
      expect(find.text('PROJECT NAME'), findsOneWidget);
      expect(find.text('PHOTOS'), findsOneWidget);
    });

    testWidgets('CATEGORY is gone — no label, and NAME is the only text field',
        (tester) async {
      await _pump(tester, const UploadChoice());

      expect(find.text('CATEGORY'), findsNothing);
      expect(find.text('Category'), findsNothing);
      // One field on the form, and it is the project name. A second TextField
      // here would mean the category input came back under another label.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('the CTA reads Upload, not Start/Create Capture', (tester) async {
      await _pump(tester, const UploadChoice());

      expect(find.text('Create & Continue'), findsNothing);
      expect(find.text('Upload'), findsOneWidget);
    });

    testWidgets('the CTA stays DISABLED until a name AND enough photos exist',
        (tester) async {
      await _pump(tester, const UploadChoice(),
          picker: _StubPicker(kProjectPhotoMinCount));

      // AppButton disables itself by taking a null onPressed.
      bool enabled() => tester
              .widget<AppButton>(find.byKey(const Key('create_project_cta')))
              .onPressed !=
          null;

      // Nothing typed, nothing picked.
      expect(enabled(), isFalse);

      // A name alone is not enough.
      await tester.enterText(find.byType(TextField).first, 'Uploaded set');
      await tester.pumpAndSettle();
      expect(enabled(), isFalse);

      // Photos alone would not be either; with both, it enables and NAMES the
      // count so the artist sees what is about to be sent.
      await tester.tap(find.byKey(const Key('create_project_add_photos')));
      await tester.pumpAndSettle();
      expect(enabled(), isTrue);
      expect(find.text('Upload $kProjectPhotoMinCount photos'), findsOneWidget);
    });

    testWidgets('below the minimum, the CTA stays disabled', (tester) async {
      await _pump(tester, const UploadChoice(),
          picker: _StubPicker(kProjectPhotoMinCount - 1));

      await tester.enterText(find.byType(TextField).first, 'Too few');
      await tester.tap(find.byKey(const Key('create_project_add_photos')));
      await tester.pumpAndSettle();

      final button =
          tester.widget<AppButton>(find.byKey(const Key('create_project_cta')));
      expect(button.onPressed, isNull);
    });
  });
}
