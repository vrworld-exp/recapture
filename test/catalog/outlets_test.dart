// Stage 16 — multi-branch: the outlet header, the brand-wide gate on a branch,
// the "From main outlet" card, and parsing of the new fields.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_notifier.dart';
import 'package:recapture/data/remote/outlet_interceptor.dart';
import 'package:recapture/domain/catalog/outlet.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/presentation/screens/catalog/outlets_screen.dart';

Map<String, dynamic> _catalog({Map<String, dynamic>? outlet}) => {
      'id': 'c1',
      'name': 'blue_cafe',
      'status': 'DRAFT',
      'isProvisioned': false,
      'hasUnpublishedChanges': false,
      'isPublishing': false,
      if (outlet != null) 'outlet': outlet,
    };

class _StubCatalog extends CatalogNotifier {
  _StubCatalog(this.map);
  final Map<String, dynamic> map;

  @override
  Future<Catalog?> build() async => Catalog.fromMap(map);
}

/// Captures the headers of each request instead of sending it.
class _Capture extends Interceptor {
  final seen = <String, Object?>{};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    seen[options.path] = options.headers[OutletInterceptor.header];
    handler.resolve(Response(requestOptions: options, statusCode: 200, data: const {}));
  }
}

void main() {
  group('OutletInterceptor', () {
    Future<Map<String, Object?>> run(String? outlet) async {
      final container = ProviderContainer(
        overrides: [selectedOutletIdProvider.overrideWith((ref) => outlet)],
      );
      addTearDown(container.dispose);
      final capture = _Capture();
      final dio = Dio();
      final probe = Provider<void>((ref) {
        dio.interceptors
          ..add(OutletInterceptor(ref))
          ..add(capture);
      });
      container.read(probe);
      for (final path in ['/catalog', '/catalog/products', '/rep/catalogs', '/auth/me']) {
        await dio.get<Object>(path);
      }
      return capture.seen;
    }

    test('adds X-Outlet-Id to /catalog calls only, and only when an outlet is picked', () async {
      final picked = await run('b1');
      expect(picked['/catalog'], 'b1');
      expect(picked['/catalog/products'], 'b1');
      expect(picked['/rep/catalogs'], isNull);
      expect(picked['/auth/me'], isNull);

      final main = await run(null);
      expect(main.values.every((v) => v == null), isTrue);
    });
  });

  group('parsing', () {
    test('catalog outlet info and product branch link', () {
      final branch = Catalog.fromMap(_catalog(outlet: {
        'role': 'BRANCH',
        'outletName': 'Baner',
        'mainCatalogId': 'm1',
      }));
      expect(branch.isBranch, isTrue);
      expect(branch.outlet!.outletName, 'Baner');
      expect(Catalog.fromMap(branch.toMap()).isBranch, isTrue);
      expect(Catalog.fromMap(_catalog()).outlet, isNull);

      final dish = CatalogProduct.fromMap({
        'id': 'p1',
        'type': 'IMAGE_ONLY',
        'name': 'Paneer',
        'currency': 'INR',
        'position': 0,
        'branch': {'followsMain': true, 'overriddenFields': ['price']},
      });
      expect(dish.branch!.overrides('price'), isTrue);
      expect(dish.copyWith(name: 'x').branch, isNotNull);

      final o = Outlet.fromMap({'id': 'm1', 'role': 'MAIN', 'name': 'Blue Cafe'});
      expect(o.isMain, isTrue);
      expect(o.label, 'Main outlet');
    });
  });

  group('BrandWideGate', () {
    Future<void> pump(WidgetTester tester, Map<String, dynamic> catalog) => tester.pumpWidget(
          ProviderScope(
            overrides: [catalogProvider.overrideWith(() => _StubCatalog(catalog))],
            child: const MaterialApp(
              home: BrandWideGate(title: 'Appearance', child: Text('EDITOR')),
            ),
          ),
        );

    testWidgets('on a branch it points to the main outlet', (tester) async {
      await pump(tester, _catalog(outlet: {'role': 'BRANCH', 'outletName': 'Baner'}));
      await tester.pumpAndSettle();
      expect(find.text('EDITOR'), findsNothing);
      expect(find.text('Set on your main outlet'), findsOneWidget);
      expect(find.byKey(const Key('brand-wide-switch')), findsOneWidget);
    });

    testWidgets('on the main outlet or a standalone restaurant it is the editor', (tester) async {
      await pump(tester, _catalog(outlet: {'role': 'MAIN'}));
      await tester.pumpAndSettle();
      expect(find.text('EDITOR'), findsOneWidget);
      await pump(tester, _catalog());
      await tester.pumpAndSettle();
      expect(find.text('EDITOR'), findsOneWidget);
    });
  });

  testWidgets('BranchLinkCard lists what the branch changed itself', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: BranchLinkCard(
              productId: 'p1',
              link: BranchLink(overriddenFields: ['price', 'assets.imageKey']),
            ),
          ),
        ),
      ),
    );
    expect(find.text('From main outlet'), findsOneWidget);
    expect(find.textContaining('own price, photo'), findsOneWidget);
    expect(find.byKey(const Key('branch-reset')), findsOneWidget);
  });
}
