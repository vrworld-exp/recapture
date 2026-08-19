// test/catalog/catalog_repository_test.dart
//
// The catalog repositories against a fake HttpClientAdapter — no network.
//
// What is worth pinning here is the WIRE contract, because a drifted path or a
// mis-shaped body is a runtime 400/404 the compiler cannot see:
//   • paths and query parameters match the routes in `recapture-api`;
//   • the backend schemas are `.strict()` and refuse an empty patch, so omitted
//     fields must be absent KEYS, not nulls;
//   • `categoryId: null` is MEANINGFUL (Uncategorized) and must survive as an
//     explicit null while an omitted category stays absent;
//   • 404 CATALOG_NOT_FOUND becomes `null`, the first-run state — every other
//     failure becomes a CatalogFailure carrying the server's own code.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/data/repositories/business_profile_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/product_type.dart';

import 'catalog_entities_test.dart' as golden;

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onFetch);

  final Future<ResponseBody> Function(RequestOptions options) onFetch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      onFetch(options);
}

ResponseBody _json(Object? body, {int status = 200}) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });

void main() {
  late List<RequestOptions> requests;

  Dio buildDio(Future<ResponseBody> Function(RequestOptions) handle) {
    requests = [];
    return Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = _FakeAdapter((o) {
        requests.add(o);
        return handle(o);
      });
  }

  /// A Dio that answers every request with one canned body.
  Dio always(Object? body, {int status = 200}) =>
      buildDio((_) async => _json(body, status: status));

  group('CatalogRepository', () {
    test('fetch returns the catalog from GET /catalog', () async {
      final repo = RemoteCatalogRepository(
        always({'status': 'success', 'catalog': golden.catalogGolden()}),
      );

      final catalog = await repo.fetch();

      expect(requests.single.uri.path, '/catalog');
      expect(requests.single.method, 'GET');
      expect(catalog?.name, 'Cafe Mocha');
    });

    test('fetch returns null — not an error — when the user has no catalog', () {
      // The 404 CATALOG_NOT_FOUND state is the first-run flow. Surfacing it as a
      // failure would put an error screen in front of every new user.
      final repo = RemoteCatalogRepository(always(
        {'status': 'error', 'code': 'CATALOG_NOT_FOUND', 'message': 'No catalog'},
        status: 404,
      ));

      expect(repo.fetch(), completion(isNull));
    });

    test('any other failure becomes a CatalogFailure carrying the server code',
        () async {
      final repo = RemoteCatalogRepository(always(
        {
          'status': 'error',
          'code': 'DUPLICATE_NAME',
          'message': 'A product with that name already exists in your catalog.',
        },
        status: 409,
      ));

      await expectLater(
        repo.createCategory('Chairs'),
        throwsA(
          isA<CatalogFailure>()
              .having((f) => f.code, 'code', CatalogErrorCodes.duplicateName)
              .having((f) => f.isDuplicateName, 'isDuplicateName', isTrue)
              .having((f) => f.statusCode, 'statusCode', 409)
              .having((f) => f.message, 'message', contains('already exists')),
        ),
      );
    });

    test('a transport failure is flagged offline, not blamed on the user',
        () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
        ..httpClientAdapter = _FakeAdapter(
          (o) async => throw DioException.connectionError(
            requestOptions: o,
            reason: 'no route to host',
          ),
        );

      await expectLater(
        RemoteCatalogRepository(dio).fetch(),
        throwsA(isA<CatalogFailure>()
            .having((f) => f.isOffline, 'isOffline', isTrue)
            .having((f) => f.code, 'code', 'OFFLINE')),
      );
    });

    test('a non-envelope error body is not shown to the user verbatim', () async {
      // A proxy's HTML error page must not reach the UI as a message.
      final dio = buildDio((o) async => ResponseBody.fromString(
            '<html>502 Bad Gateway</html>',
            502,
            headers: {
              Headers.contentTypeHeader: ['text/html'],
            },
          ));

      await expectLater(
        RemoteCatalogRepository(dio).fetch(),
        throwsA(isA<CatalogFailure>()
            .having((f) => f.code, 'code', 'UNKNOWN')
            .having((f) => f.message, 'message', isNot(contains('html')))),
      );
    });

    test('create omits businessName entirely when absent', () async {
      final repo = RemoteCatalogRepository(
        always({'status': 'success', 'catalog': golden.catalogGolden()}, status: 201),
      );

      await repo.create(name: 'Cafe Mocha');

      final body = requests.single.data as Map;
      expect(requests.single.uri.path, '/catalog');
      expect(body, {'name': 'Cafe Mocha'});
      // `.strict()` on the server: a null here would be a 400, not an ignore.
      expect(body.containsKey('businessName'), isFalse);
    });

    test('update sends only the fields it was given', () async {
      final repo = RemoteCatalogRepository(
        always({'status': 'success', 'catalog': golden.catalogGolden()}),
      );

      await repo.update(
        name: 'Renamed',
        contact: const BusinessContact(phone: '+91 90000 00000'),
      );

      final body = requests.single.data as Map;
      expect(requests.single.method, 'PATCH');
      expect(body['name'], 'Renamed');
      expect(body['contact'], {'phone': '+91 90000 00000'});
      expect(body.containsKey('businessName'), isFalse);
    });

    test('listCategories carries the uncategorized bucket alongside the list',
        () async {
      final repo = RemoteCatalogRepository(always({
        'status': 'success',
        'categories': [golden.categoryGolden()],
        'uncategorizedCount': 5,
      }));

      final list = await repo.listCategories();

      expect(requests.single.uri.path, '/catalog/categories');
      expect(list.categories.single.name, 'Chairs');
      // Feature 26: the bucket always renders, so its count must arrive with the
      // list rather than lagging it by a request.
      expect(list.uncategorizedCount, 5);
    });

    test('deleteCategory reports how many products moved to Uncategorized',
        () async {
      final repo = RemoteCatalogRepository(
        always({'status': 'success', 'movedProductCount': 3}),
      );

      expect(await repo.deleteCategory('cat-1'), 3);
      expect(requests.single.uri.path, '/catalog/categories/cat-1');
      expect(requests.single.method, 'DELETE');
    });

    test('reorderCategories posts the full ordered id list', () async {
      final repo = RemoteCatalogRepository(always({'status': 'success'}));

      await repo.reorderCategories(['a', 'b', 'c']);

      expect(requests.single.uri.path, '/catalog/categories/reorder');
      expect((requests.single.data as Map)['ids'], ['a', 'b', 'c']);
    });

    test('a 2xx without the payload fails loudly instead of rendering a blank',
        () async {
      final repo = RemoteCatalogRepository(always({'status': 'success'}));

      await expectLater(
        repo.create(name: 'X'),
        throwsA(isA<CatalogFailure>()
            .having((f) => f.code, 'code', 'MALFORMED_RESPONSE')),
      );
    });
  });

  group('CatalogProductsRepository', () {
    test('list sends every filter the grid supports', () async {
      final repo = RemoteCatalogProductsRepository(always({
        'status': 'success',
        'items': [golden.productGolden()],
        'nextCursor': 'cursor-2',
      }));

      final page = await repo.list(
        limit: 40,
        cursor: 'cursor-1',
        categoryId: 'cat-1',
        type: ProductType.threeD,
        query: '  chair ',
        includeArchived: true,
      );

      final q = requests.single.uri.queryParameters;
      expect(requests.single.uri.path, '/catalog/products');
      expect(q['limit'], '40');
      expect(q['cursor'], 'cursor-1');
      expect(q['categoryId'], 'cat-1');
      expect(q['type'], 'THREE_D');
      expect(q['q'], 'chair'); // trimmed
      expect(q['includeArchived'], 'true');
      expect(page.items.single.name, 'Walnut Chair');
      expect(page.nextCursor, 'cursor-2');
      expect(page.hasMore, isTrue);
    });

    test('list never sends the local `unknown` enum as a filter', () async {
      // `unknown` is this build's fallback for a value it does not recognise;
      // sending it would be a 400 on a `.strict()` enum.
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'items': <dynamic>[], 'nextCursor': null}),
      );

      await repo.list(type: ProductType.unknown);

      expect(requests.single.uri.queryParameters.containsKey('type'), isFalse);
    });

    test('an absent nextCursor means the last page', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'items': <dynamic>[]}),
      );

      final page = await repo.list();
      expect(page.nextCursor, isNull);
      expect(page.hasMore, isFalse);
    });

    test('create sends the model id for a 3D product', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}, status: 201),
      );

      await repo.create(
        type: ProductType.threeD,
        name: 'Walnut Chair',
        price: 4999.5,
        sourceModelId: 'model-1',
      );

      final body = requests.single.data as Map;
      expect(body['type'], 'THREE_D');
      expect(body['sourceModelId'], 'model-1');
      expect(body.containsKey('description'), isFalse);
    });

    test('update distinguishes "move to Uncategorized" from "leave the category"',
        () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}),
      );

      await repo.update('p1', name: 'Renamed');
      expect((requests.single.data as Map).containsKey('categoryId'), isFalse);

      await repo.update('p1', categoryId: null);
      final body = requests.last.data as Map;
      expect(body.containsKey('categoryId'), isTrue);
      expect(body['categoryId'], isNull);
    });

    test('archive and restore are distinct verbs, not a boolean patch', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}),
      );

      await repo.archive('p1');
      expect(requests.last.uri.path, '/catalog/products/p1/archive');
      expect(requests.last.method, 'POST');

      await repo.restore('p1');
      expect(requests.last.uri.path, '/catalog/products/p1/restore');
    });

    test('bulk sends the action and returns the affected count', () async {
      final repo =
          RemoteCatalogProductsRepository(always({'status': 'success', 'affected': 4}));

      final affected = await repo.bulk(
        action: BulkProductAction.setCategory,
        ids: ['a', 'b'],
        categoryId: null,
      );

      final body = requests.single.data as Map;
      expect(requests.single.uri.path, '/catalog/products/bulk');
      expect(body['action'], 'SET_CATEGORY');
      expect(body['ids'], ['a', 'b']);
      // SET_CATEGORY needs the key even when the value is null (Uncategorized).
      expect(body.containsKey('categoryId'), isTrue);
      expect(body['categoryId'], isNull);
      expect(affected, 4);
    });

    test('bulk omits categoryId for actions that reject it', () async {
      final repo =
          RemoteCatalogProductsRepository(always({'status': 'success', 'affected': 2}));

      await repo.bulk(action: BulkProductAction.archive, ids: ['a', 'b']);

      expect((requests.single.data as Map).containsKey('categoryId'), isFalse);
    });
  });

  group('product images and duplicate', () {
    test('uploadImageBytes posts the raw bytes with their sniffed type', () async {
      // The BYTES path, not the presigned one, is what the app actually uses:
      // a presigned PUT is cross-origin to a bucket that serves no CORS policy,
      // so it cannot work in the browser build at all. Pin the wire shape —
      // raw body, no multipart, no JSON wrapper.
      final repo = RemoteCatalogProductsRepository(always({
        'status': 'success',
        'key': 'dev/catalog/c1/products/slot/img.jpg',
      }));

      final key = await repo.uploadImageBytes(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
        contentType: 'image/jpeg',
      );

      final request = requests.single;
      expect(request.uri.path, '/catalog/products/image/bytes');
      expect(request.method, 'POST');
      expect(request.headers[Headers.contentTypeHeader], 'image/jpeg');
      expect(request.headers[Headers.contentLengthHeader], 4);
      // No product to name yet — the object is staged and bound by the create.
      expect(request.uri.queryParameters.containsKey('productId'), isFalse);
      expect(key, 'dev/catalog/c1/products/slot/img.jpg');
    });

    test('uploadImageBytes names the product when replacing an image', () async {
      final repo = RemoteCatalogProductsRepository(always({
        'status': 'success',
        'key': 'dev/catalog/c1/products/p1/img.png',
      }));

      await repo.uploadImageBytes(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        contentType: 'image/png',
        productId: 'p1',
      );

      // The query, not the body — the body is the image.
      expect(requests.single.uri.queryParameters['productId'], 'p1');
    });

    test('an upload response missing its key fails loudly', () async {
      // A 2xx without the key is a broken contract, not an empty result: the
      // create that follows would send `imageKey: null` and be refused with a
      // message about a field the user never saw.
      final repo = RemoteCatalogProductsRepository(always({'status': 'success'}));

      await expectLater(
        repo.uploadImageBytes(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
          contentType: 'image/jpeg',
        ),
        throwsA(isA<CatalogFailure>()),
      );
    });

    test('createImageSlot omits productId for the pre-create upload', () async {
      // Feature 13: an image-only product is created WITH its key, so the first
      // upload has no product to name yet.
      final repo = RemoteCatalogProductsRepository(always({
        'status': 'success',
        'key': 'dev/catalog/c1/products/slot/img.jpg',
        'url': 'https://s3/put',
        'expiresAt': '2026-08-18T10:00:00.000Z',
      }));

      final slot = await repo.createImageSlot(
        contentType: ProductImageContentType.webp,
      );

      final body = requests.single.data as Map;
      expect(requests.single.uri.path, '/catalog/products/image/upload-url');
      expect(body['contentType'], 'image/webp');
      expect(body.containsKey('productId'), isFalse);
      expect(slot.key, 'dev/catalog/c1/products/slot/img.jpg');
      expect(slot.url, 'https://s3/put');
      expect(slot.expiresAt, DateTime.parse('2026-08-18T10:00:00.000Z'));
    });

    test('createImageSlot names the product when replacing an image', () async {
      final repo = RemoteCatalogProductsRepository(always({
        'status': 'success',
        'key': 'k',
        'url': 'u',
      }));

      await repo.createImageSlot(
        contentType: ProductImageContentType.jpeg,
        productId: 'p1',
      );

      expect((requests.single.data as Map)['productId'], 'p1');
    });

    test('a slot response missing its url fails loudly', () async {
      // A slot with no url is unusable; surfacing it as a value would fail later
      // at the PUT, far from the cause.
      final repo = RemoteCatalogProductsRepository(always({'status': 'success', 'key': 'k'}));

      await expectLater(
        repo.createImageSlot(contentType: ProductImageContentType.png),
        throwsA(isA<CatalogFailure>()
            .having((f) => f.code, 'code', 'MALFORMED_RESPONSE')),
      );
    });

    test('create sends the image key for an image-only product', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}, status: 201),
      );

      await repo.create(
        type: ProductType.imageOnly,
        name: 'Mug',
        imageKey: 'dev/catalog/c1/products/slot/img.jpg',
      );

      final body = requests.single.data as Map;
      expect(body['type'], 'IMAGE_ONLY');
      expect(body['imageKey'], 'dev/catalog/c1/products/slot/img.jpg');
      expect(body.containsKey('sourceModelId'), isFalse);
    });

    test('commitImage PUTs the key to the product', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}),
      );

      await repo.commitImage('p1', 'dev/catalog/c1/products/p1/img.jpg');

      expect(requests.single.uri.path, '/catalog/products/p1/image');
      expect(requests.single.method, 'PUT');
      expect((requests.single.data as Map)['key'], 'dev/catalog/c1/products/p1/img.jpg');
    });

    test('a conversion carries its asset in the same request', () async {
      // The server refuses a type change that arrives without the asset its new
      // type needs, so the client must never split them across two calls.
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}),
      );

      await repo.update('p1', type: ProductType.threeD, sourceModelId: 'm1');

      final body = requests.single.data as Map;
      expect(body['type'], 'THREE_D');
      expect(body['sourceModelId'], 'm1');
    });

    test('update never sends the local unknown type', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}),
      );

      await repo.update('p1', name: 'X', type: ProductType.unknown);

      expect((requests.single.data as Map).containsKey('type'), isFalse);
    });

    test('duplicate omits the name when the server should choose it', () async {
      final repo = RemoteCatalogProductsRepository(
        always({'status': 'success', 'product': golden.productGolden()}, status: 201),
      );

      await repo.duplicate('p1');
      expect(requests.single.uri.path, '/catalog/products/p1/duplicate');
      expect(requests.single.data as Map, isEmpty);

      await repo.duplicate('p1', name: 'Chosen');
      expect((requests.last.data as Map)['name'], 'Chosen');
    });
  });

  group('branding uploads', () {
    test('createBrandingSlot names the slot', () async {
      final repo = RemoteCatalogRepository(always({
        'status': 'success',
        'key': 'dev/catalog/c1/products/logo/img.png',
        'url': 'https://s3/put',
      }));

      await repo.createBrandingSlot(
        slot: BrandingSlot.cover,
        contentType: ProductImageContentType.png,
      );

      final body = requests.single.data as Map;
      expect(requests.single.uri.path, '/catalog/logo/upload-url');
      expect(body['slot'], 'cover');
      expect(body['contentType'], 'image/png');
    });

    test('commitBranding returns the refreshed profile', () async {
      final repo = RemoteCatalogRepository(
        always({'status': 'success', 'profile': golden.profileGolden()}),
      );

      final profile = await repo.commitBranding(
        slot: BrandingSlot.logo,
        key: 'dev/catalog/c1/products/logo/img.png',
      );

      expect(requests.single.uri.path, '/catalog/logo');
      expect(requests.single.method, 'PUT');
      expect((requests.single.data as Map)['slot'], 'logo');
      expect(profile.logoUrl, 'https://cdn.example.com/logo.jpg');
    });
  });

  group('BusinessProfileRepository', () {
    test('fetch reads GET /catalog/profile', () async {
      final repo = RemoteBusinessProfileRepository(
        always({'status': 'success', 'profile': golden.profileGolden()}),
      );

      final profile = await repo.fetch();

      expect(requests.single.uri.path, '/catalog/profile');
      expect(profile?.businessName, 'Mocha Foods Pvt Ltd');
      expect(profile?.isPublic('contact.phone'), isTrue);
    });

    test('fetch returns null when the user has no catalog yet', () {
      final repo = RemoteBusinessProfileRepository(always(
        {'status': 'error', 'code': 'CATALOG_NOT_FOUND', 'message': 'No catalog'},
        status: 404,
      ));

      expect(repo.fetch(), completion(isNull));
    });

    test('update PATCHes only the supplied fields', () async {
      final repo = RemoteBusinessProfileRepository(
        always({'status': 'success', 'profile': golden.profileGolden()}),
      );

      await repo.update(
        businessName: 'Mocha Foods Pvt Ltd',
        contact: const BusinessContact(
          phone: '+91 90000 00000',
          socials: BusinessSocials(instagram: 'mocha'),
        ),
      );

      final body = requests.single.data as Map;
      expect(requests.single.uri.path, '/catalog/profile');
      expect(requests.single.method, 'PATCH');
      expect(body['businessName'], 'Mocha Foods Pvt Ltd');
      expect(body['contact'], {
        'phone': '+91 90000 00000',
        'socials': {'instagram': 'mocha'},
      });
      expect(body.containsKey('name'), isFalse);
    });
  });
}
