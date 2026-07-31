// test/projects/image_prep_screen_test.dart
//
// Prepare-Images screen: renders a thumbnail per selected photo; flags edited
// images; lighting Apply-to-all fans out (lighting only); back with edits asks
// for confirmation; Generate is disabled while exporting; untouched photos
// pass through by ORIGINAL key with zero uploads, edited ones swap to their
// uploaded model-input key. Hermetic: fake loader/exporter/repo — no network,
// no isolates, no Hive (the screen watches no role provider).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/projects/image_prep_exporter.dart';
import 'package:recapture/application/projects/image_prep_image_loader.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/image_edit.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/preview_manifest.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/image_prep_screen.dart';
import 'repo_fake_defaults.dart';

/// Tiny but real PNG so the header decode in _load finds dimensions.
final Uint8List _pngBytes = Uint8List.fromList(
  img.encodePng(img.Image(width: 8, height: 6, numChannels: 3)),
);

class _FakeLoader implements PrepImageLoader {
  _FakeLoader({Map<String, int>? failuresFor})
      : failuresFor = {...?failuresFor};

  /// key → how many of ITS loads must fail before one succeeds. Models the
  /// real thing: a photo whose first fetch dies (CORS, expired presign) and
  /// then loads on retry.
  final Map<String, int> failuresFor;

  int calls = 0;
  final projectIds = <String>[];

  @override
  Future<LoadedPrepImage> load(String projectId, PreviewPhoto photo) async {
    calls++;
    projectIds.add(projectId);
    final remaining = failuresFor[photo.key] ?? 0;
    if (remaining > 0) {
      failuresFor[photo.key] = remaining - 1;
      throw StateError('load failed');
    }
    return LoadedPrepImage(bytes: _pngBytes, width: 8, height: 6);
  }
}

class _FakeExporter implements ImagePrepExporter {
  _FakeExporter({this.gate});

  /// When set, exports block on this — the "disabled while exporting" probe.
  final Completer<void>? gate;
  int calls = 0;

  @override
  Future<ExportedImage> export(
      Uint8List originalBytes, ImageEditState edit) async {
    calls++;
    await gate?.future;
    // Real decodable bytes: after "Save" the screen DISPLAYS the bake, so a
    // dummy byte list would blow up in the image codec rather than in a test
    // expectation.
    return ExportedImage(
      jpegBytes: _pngBytes,
      width: 8,
      height: 6,
      isTight: false,
    );
  }
}

class _FakeRepo
    with FakeModelGenerationDefaults,
        FakeAdminDeleteDefaults,
        FakeAutoGenerationDefaults
    implements LiveProjectsRepository {
  int uploadUrlRequests = 0;
  int uploadedImages = 0;
  List<String>? createdWithKeys;

  /// When true, createModel fails the way a dead connection does.
  bool failCreate = false;

  /// Keys the Prepare-Images loader fell back to the API proxy for.
  final proxyFetches = <String>[];

  static const model = ProjectModelView(
    id: 'm1',
    source: ModelSource.meshy,
    status: ModelStatus.queued,
  );

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async => const {};

  @override
  Future<PreviewDeleteResult> deletePhotos(
          String projectId, List<String> keys) async =>
      const PreviewDeleteResult(deleted: [], missing: []);

  @override
  Future<Uint8List> fetchPhotoBytes(String projectId, String key) async {
    proxyFetches.add(key);
    return _pngBytes;
  }

  @override
  Future<List<ModelImageUploadSlot>> requestModelImageUploads(
    String projectId,
    int count,
  ) async {
    uploadUrlRequests++;
    return [
      for (var i = 0; i < count; i++)
        ModelImageUploadSlot(
          key: 'model-input/session/photo_${i + 1}.jpg',
          url: 'https://signed-put/$i',
        ),
    ];
  }

  @override
  Future<void> uploadModelImage(
      ModelImageUploadSlot slot, Uint8List bytes) async {
    uploadedImages++;
  }

  @override
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  }) async {
    if (failCreate) {
      throw const LiveProjectsException(LiveProjectsFailure.network);
    }
    createdWithKeys = keys;
    return model;
  }

  @override
  Future<List<ProjectModelView>> listModels(String projectId) async =>
      [if (createdWithKeys != null) model];
}

const _photos = [
  PreviewPhoto(key: 'images/EYE/a.jpg', url: 'https://signed/a', size: 1),
  PreviewPhoto(key: 'images/EYE/b.jpg', url: 'https://signed/b', size: 1),
  PreviewPhoto(key: 'images/TOP/c.jpg', url: 'https://signed/c', size: 1),
];

/// Hosts the screen behind a push so pop results and back navigation behave
/// like production.
Widget _app(
  _FakeRepo repo,
  _FakeLoader loader,
  _FakeExporter exporter, {
  required ValueChanged<ProjectModelView?> onResult,
}) {
  return ProviderScope(
    overrides: [
      liveProjectsRepositoryProvider.overrideWithValue(repo),
      prepImageLoaderProvider.overrideWithValue(loader),
      imagePrepExporterProvider.overrideWithValue(exporter),
    ],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('open_prep'),
              onPressed: () async {
                final result =
                    await Navigator.of(context).push<ProjectModelView>(
                  MaterialPageRoute(
                    builder: (_) => const ImagePrepScreen(
                      projectId: 'p1',
                      photos: _photos,
                    ),
                  ),
                );
                onResult(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Waits out a confirmation snackbar. It sits over the bottom bar, so a tap on
/// the Generate CTA lands on the toast until it goes away — in the app as well
/// as here, which is why the confirmations are short-lived.
Future<void> _settleSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open_prep')));
  // Let the route transition finish and the fake loads resolve. Safe to
  // settle here: with all photos loaded the screen has no looping animation.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a thumbnail per photo; no edited badges initially',
      (tester) async {
    final repo = _FakeRepo();
    final loader = _FakeLoader();
    await tester
        .pumpWidget(_app(repo, loader, _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    expect(loader.calls, 3);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('prep_thumb_$i')), findsOneWidget);
      expect(find.byKey(ValueKey('prep_edited_badge_$i')), findsNothing);
    }
    expect(find.text('Editing is optional — photos are used as-is'),
        findsOneWidget);
  });

  testWidgets('rotate marks the active image edited (badge appears)',
      (tester) async {
    await tester.pumpWidget(
        _app(_FakeRepo(), _FakeLoader(), _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
    await tester.pump();

    expect(find.byKey(const ValueKey('prep_edited_badge_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('prep_edited_badge_1')), findsNothing);
  });

  testWidgets('lighting Apply-to-all fans lighting out to every image',
      (tester) async {
    await tester.pumpWidget(
        _app(_FakeRepo(), _FakeLoader(), _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_tool_lighting')));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('prep_slider_brightness')),
        const Offset(80, 0));
    await tester.pump();
    // The slider edit marks only the ACTIVE image.
    expect(find.byKey(const ValueKey('prep_edited_badge_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('prep_edited_badge_1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('prep_lighting_apply_all')));
    await tester.pump();

    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('prep_edited_badge_$i')), findsOneWidget);
    }
  });

  testWidgets('back with edits asks to discard; cancel stays, confirm leaves',
      (tester) async {
    ProjectModelView? result = _FakeRepo.model; // sentinel ≠ null
    await tester.pumpWidget(_app(_FakeRepo(), _FakeLoader(), _FakeExporter(),
        onResult: (r) => result = r));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
    await tester.pump();

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(find.byKey(const ValueKey('prep_discard_dialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prep_discard_cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('prep_generate_cta')), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prep_discard_confirm')));
    await tester.pumpAndSettle(); // dialog close + route pop transition
    expect(find.byKey(const ValueKey('prep_generate_cta')), findsNothing);
    expect(result, isNull); // popped without a created model
  });

  testWidgets('back with NO edits pops silently', (tester) async {
    await tester.pumpWidget(
        _app(_FakeRepo(), _FakeLoader(), _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle(); // route pop transition
    expect(find.byKey(const ValueKey('prep_discard_dialog')), findsNothing);
    expect(find.byKey(const ValueKey('prep_generate_cta')), findsNothing);
  });

  testWidgets(
      'untouched photos: zero uploads, createModel gets ORIGINAL keys, pops with the model',
      (tester) async {
    final repo = _FakeRepo();
    ProjectModelView? result;
    final exporter = _FakeExporter();
    await tester.pumpWidget(
        _app(repo, _FakeLoader(), exporter, onResult: (r) => result = r));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(exporter.calls, 0);
    expect(repo.uploadUrlRequests, 0);
    expect(repo.uploadedImages, 0);
    expect(repo.createdWithKeys,
        ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg']);
    expect(result?.id, 'm1');
  });

  testWidgets(
      'edited photo is exported + uploaded and swaps to its model-input key',
      (tester) async {
    final repo = _FakeRepo();
    final exporter = _FakeExporter();
    await tester
        .pumpWidget(_app(repo, _FakeLoader(), exporter, onResult: (_) {}));
    await _open(tester);

    // Edit only the SECOND image.
    await tester.tap(find.byKey(const ValueKey('prep_thumb_1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(exporter.calls, 1);
    expect(repo.uploadUrlRequests, 1);
    expect(repo.uploadedImages, 1);
    expect(repo.createdWithKeys, [
      'images/EYE/a.jpg',
      'model-input/session/photo_1.jpg',
      'images/TOP/c.jpg',
    ]);
  });

  testWidgets(
      'REGRESSION: Generate with the crop editor still open APPLIES the draft '
      'and generates — it used to be a dead button', (tester) async {
    final repo = _FakeRepo();
    final exporter = _FakeExporter();
    ProjectModelView? result;
    await tester.pumpWidget(
        _app(repo, _FakeLoader(), exporter, onResult: (r) => result = r));
    await _open(tester);

    // Open the rectangle crop and DON'T tap Apply — the state a staff user is
    // in the moment they decide the photo is ready.
    await tester.tap(find.byKey(const ValueKey('prep_tool_rect')));
    await tester.pump();
    expect(find.byKey(const ValueKey('prep_rect_apply')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The draft was committed, baked, uploaded, and the model requested.
    expect(exporter.calls, 1);
    expect(repo.uploadedImages, 1);
    expect(repo.createdWithKeys, [
      'model-input/session/photo_1.jpg',
      'images/EYE/b.jpg',
      'images/TOP/c.jpg',
    ]);
    expect(result?.id, 'm1');
  });

  testWidgets(
      'Generate with an unusable outline SAYS why instead of doing nothing',
      (tester) async {
    final repo = _FakeRepo();
    final exporter = _FakeExporter();
    await tester
        .pumpWidget(_app(repo, _FakeLoader(), exporter, onResult: (_) {}));
    await _open(tester);

    // Outline tool open with no points drawn: nothing to apply.
    await tester.tap(find.byKey(const ValueKey('prep_tool_polygon')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();

    expect(
      find.textContaining('at least 3 points'),
      findsOneWidget,
      reason: 'a refused press must explain itself',
    );
    expect(exporter.calls, 0);
    expect(repo.createdWithKeys, isNull);
  });

  testWidgets('a photo that failed to load names itself and refuses out loud',
      (tester) async {
    final repo = _FakeRepo();
    // Second photo fails its FIRST load only.
    final loader = _FakeLoader(failuresFor: {'images/EYE/b.jpg': 1});
    await tester
        .pumpWidget(_app(repo, loader, _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    // Stated in the bottom bar, next to a Retry affordance…
    expect(
      find.text('1 of 3 photos couldn’t be loaded. '
          'Tap Retry to fetch them again.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('prep_retry_failed_loads')),
        findsOneWidget);

    // …and the CTA still RESPONDS: it explains itself rather than sitting
    // greyed out doing nothing, which is what read as "the app is broken".
    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();
    expect(find.widgetWithText(SnackBar, '1 of 3 photos couldn’t be loaded. '
        'Tap Retry to fetch them again.'), findsOneWidget);
    expect(repo.createdWithKeys, isNull);
  });

  testWidgets('Retry re-fetches the failed photo and Generate then works',
      (tester) async {
    final repo = _FakeRepo();
    final loader = _FakeLoader(failuresFor: {'images/EYE/b.jpg': 1});
    await tester
        .pumpWidget(_app(repo, loader, _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_retry_failed_loads')));
    await tester.pumpAndSettle();
    expect(loader.calls, 4); // 3 initial + 1 retry
    expect(find.byKey(const ValueKey('prep_retry_failed_loads')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repo.createdWithKeys,
        ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg']);
  });

  group('Save (app bar) — the edit becomes the photo', () {
    testWidgets('bakes the active photo: edit clears, badge flips to saved',
        (tester) async {
      final exporter = _FakeExporter();
      await tester.pumpWidget(
          _app(_FakeRepo(), _FakeLoader(), exporter, onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
      await tester.pump();
      expect(find.byKey(const ValueKey('prep_edited_badge_0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prep_save_edit')));
      await tester.pumpAndSettle();

      expect(exporter.calls, 1);
      // The pending edit is gone — it lives in the pixels now — and the strip
      // says "saved" rather than "edited".
      expect(find.byKey(const ValueKey('prep_edited_badge_0')), findsNothing);
      expect(find.byKey(const ValueKey('prep_saved_badge_0')), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Saved'), findsOneWidget);
      expect(find.text('1 of 3 photos edited'), findsOneWidget);
    });

    testWidgets('Save with the crop editor open commits the draft first',
        (tester) async {
      final exporter = _FakeExporter();
      await tester.pumpWidget(
          _app(_FakeRepo(), _FakeLoader(), exporter, onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('prep_tool_rect')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('prep_save_edit')));
      await tester.pumpAndSettle();

      expect(exporter.calls, 1);
      expect(find.byKey(const ValueKey('prep_saved_badge_0')), findsOneWidget);
      // The editor closed with the save.
      expect(find.byKey(const ValueKey('prep_rect_apply')), findsNothing);
    });

    testWidgets('Generate uploads the SAVED bytes without re-baking them',
        (tester) async {
      final repo = _FakeRepo();
      final exporter = _FakeExporter();
      await tester
          .pumpWidget(_app(repo, _FakeLoader(), exporter, onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('prep_save_edit')));
      await tester.pumpAndSettle();
      await _settleSnack(tester);

      await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(exporter.calls, 1, reason: 'the save WAS the bake');
      expect(repo.uploadedImages, 1);
      expect(repo.createdWithKeys, [
        'model-input/session/photo_1.jpg',
        'images/EYE/b.jpg',
        'images/TOP/c.jpg',
      ]);
    });

    testWidgets('editing again after a save stacks on the saved version',
        (tester) async {
      final repo = _FakeRepo();
      final exporter = _FakeExporter();
      await tester
          .pumpWidget(_app(repo, _FakeLoader(), exporter, onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('prep_save_edit')));
      await tester.pumpAndSettle();
      await _settleSnack(tester);

      // A second edit on top of the saved pixels.
      await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
      await tester.pump();
      expect(find.byKey(const ValueKey('prep_edited_badge_0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // One bake for the save, one for the pending edit — but still ONE upload.
      expect(exporter.calls, 2);
      expect(repo.uploadedImages, 1);
      expect(repo.createdWithKeys?.first, 'model-input/session/photo_1.jpg');
    });

    testWidgets('Revert restores the original and drops it from the upload set',
        (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(
          _app(repo, _FakeLoader(), _FakeExporter(), onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('prep_save_edit')));
      await tester.pumpAndSettle();
      await _settleSnack(tester);
      expect(find.byKey(const ValueKey('prep_tool_revert')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prep_tool_revert')));
      await tester.pumpAndSettle();
      await _settleSnack(tester);
      expect(find.byKey(const ValueKey('prep_saved_badge_0')), findsNothing);
      expect(find.byKey(const ValueKey('prep_tool_revert')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(repo.uploadedImages, 0);
      expect(repo.createdWithKeys,
          ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg']);
    });

    testWidgets('Save with nothing to save says so instead of sitting inert',
        (tester) async {
      final exporter = _FakeExporter();
      await tester.pumpWidget(
          _app(_FakeRepo(), _FakeLoader(), exporter, onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('prep_save_edit')));
      await tester.pump();

      expect(find.text('Crop, rotate or adjust the photo first, then save.'),
          findsOneWidget);
      expect(exporter.calls, 0);
    });
  });

  testWidgets('a failed generation shows a dialog, not a fading toast',
      (tester) async {
    final repo = _FakeRepo()..failCreate = true;
    await tester.pumpWidget(
        _app(repo, _FakeLoader(), _FakeExporter(), onResult: (_) {}));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('prep_generate_error')), findsOneWidget);
    expect(find.text('You’re offline — check your connection and try again.'),
        findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('prep_generate_error_dismiss')));
    await tester.pumpAndSettle();
    // Dismissing returns to the screen with the CTA live for another attempt.
    expect(find.byKey(const ValueKey('prep_generate_cta')), findsOneWidget);
  });

  testWidgets('Generate is disabled (loading) while the export is in flight',
      (tester) async {
    final repo = _FakeRepo();
    final gate = Completer<void>();
    final exporter = _FakeExporter(gate: gate);
    ProjectModelView? result;
    await tester.pumpWidget(
        _app(repo, _FakeLoader(), exporter, onResult: (r) => result = r));
    await _open(tester);

    await tester.tap(find.byKey(const ValueKey('prep_tool_rotate')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
    await tester.pump();

    // Blocked on the exporter: hint flips, CTA is in its loading state, and a
    // second tap cannot start a second run.
    expect(find.text('Preparing and uploading your edited photos…'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('prep_generate_cta')),
        warnIfMissed: false);
    await tester.pump();
    expect(exporter.calls, 1);

    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(result?.id, 'm1');
    expect(repo.uploadedImages, 1);
  });
}
