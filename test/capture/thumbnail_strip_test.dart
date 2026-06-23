// test/capture/thumbnail_strip_test.dart
//
// Widget tests for the recent-capture thumbnail strip: newest-first ordering,
// the visible-count cap, downscale-decode (ResizeImage / cacheWidth) so tiles
// never decode full-res, the empty state, graceful handling of a missing file,
// and the tap callback.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_thumbnail.dart';
import 'package:recapture/presentation/widgets/thumbnail_strip.dart';

CaptureThumbnail _t(String id, {int atMs = 0, String? path}) => CaptureThumbnail(
      id: id,
      filePath: path ?? '/tmp/$id.jpg',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(atMs),
    );

Future<void> _pump(
  WidgetTester tester,
  List<CaptureThumbnail> recent, {
  int maxVisible = 5,
  void Function(CaptureThumbnail)? onTap,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: ThumbnailStrip(
              recent: recent,
              maxVisible: maxVisible,
              onTapThumbnail: onTap,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('CaptureThumbnail value equality', () {
    final a = DateTime(2026);
    expect(
      CaptureThumbnail(id: '1', filePath: '/a', capturedAt: a),
      CaptureThumbnail(id: '1', filePath: '/a', capturedAt: a),
    );
    expect(
      CaptureThumbnail(id: '1', filePath: '/a', capturedAt: a) ==
          CaptureThumbnail(id: '2', filePath: '/a', capturedAt: a),
      isFalse,
    );
  });

  testWidgets('empty list renders no tiles, no crash', (tester) async {
    await _pump(tester, const []);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders one tile per capture', (tester) async {
    await _pump(tester, [_t('a', atMs: 1), _t('b', atMs: 2)]);
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('caps the visible count at maxVisible', (tester) async {
    await _pump(
      tester,
      [for (var i = 0; i < 6; i++) _t('id$i', atMs: i)],
      maxVisible: 3,
    );
    expect(find.byType(Image), findsNWidgets(3));
  });

  testWidgets('orders newest-first (newest at the leading/left edge)',
      (tester) async {
    await _pump(tester, [_t('old', atMs: 1), _t('new', atMs: 9)]);
    await tester.pump(const Duration(milliseconds: 300)); // settle entry slide

    final newX = tester.getTopLeft(find.byKey(const ValueKey('new'))).dx;
    final oldX = tester.getTopLeft(find.byKey(const ValueKey('old'))).dx;
    expect(newX, lessThan(oldX));
  });

  testWidgets('decodes thumbnails downscaled (ResizeImage, not full-res)',
      (tester) async {
    await _pump(tester, [_t('a', atMs: 1)]);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    expect((image.image as ResizeImage).width, isNotNull);
  });

  testWidgets('missing file is handled gracefully (no crash)', (tester) async {
    await _pump(tester, [_t('a', atMs: 1, path: '/no/such/file.jpg')]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('tap fires the callback with the tapped thumbnail',
      (tester) async {
    CaptureThumbnail? tapped;
    await _pump(
      tester,
      [_t('a', atMs: 1)],
      onTap: (t) => tapped = t,
      reduceMotion: true, // no entry animation to wait on
    );
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pump();
    expect(tapped?.id, 'a');
  });

  testWidgets('reduce-motion renders instantly without perpetual animation',
      (tester) async {
    await _pump(tester, [_t('a', atMs: 1)], reduceMotion: true);
    expect(find.byType(Image), findsOneWidget);
  });
}
