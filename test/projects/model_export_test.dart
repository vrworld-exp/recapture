// test/projects/model_export_test.dart
//
// The staff-only "Export model" action on the 3D model viewer:
//   • the button exists for staff (ADMIN / MODEL_ARTIST) and NEVER for the
//     owner — role watched inside the screen, so every caller is gated;
//   • a GLB-only model exports immediately (no format sheet);
//   • with a USDZ too, a format sheet offers both and delivers the picked one;
//   • a failed export shows mapped copy — never the URL;
//   • re-entrancy: the button disables while an export is in flight.
// The exporter is faked through modelExporterProvider — no network, no share
// sheet, no browser.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/model_export_service.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/model_viewer_screen.dart';

const _glbOnly = ProjectModelView(
  id: 'm1',
  source: ModelSource.meshy,
  status: ModelStatus.succeeded,
  glbUrl: 'https://cdn/model.glb',
);

const _glbAndUsdz = ProjectModelView(
  id: 'm2',
  source: ModelSource.meshy,
  status: ModelStatus.succeeded,
  glbUrl: 'https://cdn/model.glb',
  usdzUrl: 'https://cdn/model.usdz',
);

class _FakeExporter implements ModelExporter {
  final calls = <ModelExportFile>[];
  Object? throwOnExport;

  /// When set, export() parks on this until completed — for in-flight tests.
  Completer<void>? gate;

  @override
  Future<void> export(ModelExportFile file) async {
    calls.add(file);
    if (gate case final g?) await g.future;
    if (throwOnExport case final e?) throw e;
  }
}

void main() {
  Widget app({
    required bool staff,
    required _FakeExporter exporter,
    ProjectModelView model = _glbOnly,
  }) {
    return ProviderScope(
      overrides: [
        isStaffProvider.overrideWithValue(staff),
        modelExporterProvider.overrideWithValue(exporter),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ModelViewerScreen(
          model: model,
          renderBuilder: (_, __) => const SizedBox.expand(),
        ),
      ),
    );
  }

  const btn = ValueKey('model_export_btn');

  testWidgets('staff sees the Export button; the owner never does',
      (tester) async {
    await tester.pumpWidget(app(staff: true, exporter: _FakeExporter()));
    expect(find.byKey(btn), findsOneWidget);

    await tester.pumpWidget(app(staff: false, exporter: _FakeExporter()));
    expect(find.byKey(btn), findsNothing);
  });

  testWidgets('GLB-only model exports immediately — no format sheet',
      (tester) async {
    final exporter = _FakeExporter();
    await tester.pumpWidget(app(staff: true, exporter: exporter));

    await tester.tap(find.byKey(btn));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('model_export_glb')), findsNothing);
    expect(exporter.calls, hasLength(1));
    final file = exporter.calls.single;
    expect(file.url, 'https://cdn/model.glb');
    expect(file.fileName, 'recapture-model-m1.glb');
    expect(file.mimeType, 'model/gltf-binary');
  });

  testWidgets('GLB+USDZ model asks for the format; picking USDZ delivers it',
      (tester) async {
    final exporter = _FakeExporter();
    await tester.pumpWidget(
        app(staff: true, exporter: exporter, model: _glbAndUsdz));

    await tester.tap(find.byKey(btn));
    await tester.pumpAndSettle();

    // The sheet offers both, and nothing is exported until a pick.
    expect(find.byKey(const ValueKey('model_export_glb')), findsOneWidget);
    expect(find.byKey(const ValueKey('model_export_usdz')), findsOneWidget);
    expect(exporter.calls, isEmpty);

    await tester.tap(find.byKey(const ValueKey('model_export_usdz')));
    await tester.pumpAndSettle();

    expect(exporter.calls, hasLength(1));
    final file = exporter.calls.single;
    expect(file.url, 'https://cdn/model.usdz');
    expect(file.fileName, 'recapture-model-m2.usdz');
    expect(file.mimeType, 'model/vnd.usdz+zip');
  });

  testWidgets('dismissing the format sheet exports nothing', (tester) async {
    final exporter = _FakeExporter();
    await tester.pumpWidget(
        app(staff: true, exporter: exporter, model: _glbAndUsdz));

    await tester.tap(find.byKey(btn));
    await tester.pumpAndSettle();
    // Tap the barrier above the sheet.
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();

    expect(exporter.calls, isEmpty);
  });

  testWidgets('a failed export shows mapped copy — never the URL',
      (tester) async {
    final exporter = _FakeExporter()..throwOnExport = StateError('403 https://cdn/model.glb');
    await tester.pumpWidget(app(staff: true, exporter: exporter));

    await tester.tap(find.byKey(btn));
    await tester.pumpAndSettle();

    expect(find.text('Couldn’t export this model. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('https://'), findsNothing);
    expect(find.textContaining('cdn'), findsNothing);
  });

  testWidgets('the button disables while an export is in flight',
      (tester) async {
    final exporter = _FakeExporter()..gate = Completer<void>();
    await tester.pumpWidget(app(staff: true, exporter: exporter));

    await tester.tap(find.byKey(btn));
    await tester.pump();

    // Second tap while busy: the button is disabled, no second delivery.
    await tester.tap(find.byKey(btn), warnIfMissed: false);
    await tester.pump();
    expect(exporter.calls, hasLength(1));

    exporter.gate!.complete();
    await tester.pumpAndSettle();
    expect(exporter.calls, hasLength(1));
  });
}
