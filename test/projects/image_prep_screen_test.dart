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
  int calls = 0;
  final projectIds = <String>[];

  @override
  Future<LoadedPrepImage> load(String projectId, PreviewPhoto photo) async {
    calls++;
    projectIds.add(projectId);
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
    return ExportedImage(
      jpegBytes: Uint8List.fromList([1, 2, 3]),
      width: 2000,
      height: 1500,
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
