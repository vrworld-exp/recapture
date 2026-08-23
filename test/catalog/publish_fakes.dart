// test/catalog/publish_fakes.dart
//
// The publish surface, faked. Shared by publish_screen_test and qr_screen_test
// because both drive the same repository seam and the same link actions, and a
// second copy would drift.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/catalog/publish_status.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';

import 'catalog_entities_test.dart' as golden;

/// A publish status payload, in EXACTLY the shape `getPublishStatus` emits.
///
/// Built as a raw map rather than a constructed entity on purpose: these tests
/// are as much about the PARSE as about the render, and the one thing that must
/// never work is a `message` field reaching the screen.
Map<String, dynamic> statusPayload({
  String status = 'DRAFT',
  bool hasDraftChanges = true,
  String? publicUrl,
  String? lastPublishedAt,
  String? activeRunId,
  Map<String, dynamic>? run,
  List<Map<String, dynamic>> products = const [],
  List<Map<String, dynamic>> gates = const [],
}) =>
    {
      'status': status,
      'hasDraftChanges': hasDraftChanges,
      'publicUrl': publicUrl,
      'lastPublishedAt': lastPublishedAt,
      'activeRunId': activeRunId,
      'run': run,
      'products': products,
      'gates': gates,
    };

Map<String, dynamic> runPayload({
  String id = 'run-1',
  String state = 'RUNNING',
  String mode = 'FULL',
  int total = 10,
  int synced = 0,
  int failed = 0,
  int skipped = 0,
  Map<String, dynamic>? error,
}) =>
    {
      'id': id,
      'state': state,
      'mode': mode,
      'counts': {
        'total': total,
        'synced': synced,
        'failed': failed,
        'skipped': skipped,
      },
      'startedAt': '2026-08-23T10:00:00.000Z',
      'finishedAt': null,
      if (error != null) 'error': error,
    };

Map<String, dynamic> productPayload({
  required String id,
  required String name,
  String syncStatus = 'SYNCED',
  String type = 'THREE_D',
  String? code,
  String? message,
}) =>
    {
      'id': id,
      'name': name,
      'type': type,
      'syncStatus': syncStatus,
      if (code != null) 'code': code,
      if (message != null) 'message': message,
    };

Map<String, dynamic> gatePayload({
  required String code,
  required String message,
  String? productId,
  String? productName,
}) =>
    {
      'code': code,
      'message': message,
      if (productId != null) 'productId': productId,
      if (productName != null) 'productName': productName,
    };

/// A catalog repository whose publish surface the test drives.
class FakePublishRepository implements CatalogRepository {
  FakePublishRepository({
    Map<String, dynamic>? status,
    Catalog? catalog,
  })  : _status = status ?? statusPayload(),
        catalog = catalog ?? Catalog.fromMap(golden.catalogGolden());

  Map<String, dynamic> _status;
  Catalog? catalog;

  /// Every `GET /catalog/publish/status`, counted — the poll-loop tests are
  /// entirely about this number.
  int statusCalls = 0;

  int publishCalls = 0;
  int retryCalls = 0;
  int unpublishCalls = 0;
  final List<String?> idempotencyKeys = [];
  final List<CatalogQrFormat> qrCalls = [];

  /// What the next publish/retry answers. Defaults to a queued run.
  PublishRequestResult publishResult = const PublishQueued(runId: 'run-1');
  UnpublishResult unpublishResult = const UnpublishQueued('run-2');

  /// Set to fail the next status read.
  CatalogFailure? statusFailure;

  /// Set to fail the next publish/retry — the lost-response case the
  /// idempotency key exists for.
  CatalogFailure? publishFailure;

  /// Set to fail the next QR fetch.
  CatalogFailure? qrFailure;

  /// Advances what the next status read returns — how a test moves a run on.
  void setStatus(Map<String, dynamic> status) => _status = status;

  @override
  Future<PublishStatus> publishStatus() async {
    statusCalls++;
    if (statusFailure != null) throw statusFailure!;
    return PublishStatus.fromMap(_status);
  }

  @override
  Future<PublishRequestResult> publish({String? idempotencyKey}) async {
    publishCalls++;
    idempotencyKeys.add(idempotencyKey);
    if (publishFailure != null) throw publishFailure!;
    return publishResult;
  }

  @override
  Future<PublishRequestResult> retryFailedPublish() async {
    retryCalls++;
    if (publishFailure != null) throw publishFailure!;
    return publishResult;
  }

  @override
  Future<UnpublishResult> unpublish() async {
    unpublishCalls++;
    return unpublishResult;
  }

  @override
  Future<CatalogQrImage> fetchQr({
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) async {
    qrCalls.add(format);
    if (qrFailure != null) throw qrFailure!;
    return CatalogQrImage(
      bytes: Uint8List.fromList(utf8.encode('qr-bytes-${format.apiValue}')),
      contentType:
          format == CatalogQrFormat.png ? 'image/png' : 'application/pdf',
      fileName: 'cafe-mocha-qr.${format.apiValue}',
      format: format,
    );
  }

  // ── The rest of the seam, not exercised here ──────────────────────────────

  @override
  Future<Catalog?> fetch() async => catalog;

  @override
  Future<CatalogCategoryList> listCategories() async =>
      CatalogCategoryList.empty;

  @override
  Future<Catalog> create({required String name, String? businessName}) =>
      throw UnimplementedError();

  @override
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) async {
    final current = catalog;
    if (current != null && name != null) {
      catalog = current.copyWith(name: name);
    }
    return catalog!;
  }

  @override
  Future<ProductImageSlot> createBrandingSlot({
    required BrandingSlot slot,
    required ProductImageContentType contentType,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> uploadBrandingBytes(
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) =>
      throw UnimplementedError();

  @override
  Future<BusinessProfile> commitBranding({
    required BrandingSlot slot,
    required String key,
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

/// A QR deliverer that records instead of opening a share sheet or a browser.
class FakeQrDeliverer implements QrDeliverer {
  final List<QrDownloadFile> delivered = [];

  /// Set to fail the next delivery (a dismissed share sheet, a refused
  /// download).
  Object? failure;

  /// Completed by the test to finish a delivery — how a test holds one open
  /// long enough to look at the screen mid-save.
  Completer<void>? gate;

  @override
  Future<void> deliver(QrDownloadFile file) async {
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    delivered.add(file);
  }
}

/// Link actions with the platform's capabilities under the test's control —
/// which is the whole point: a mobile build offers Share and no Open, a web
/// build the reverse, and neither is decided by `kIsWeb` in the widget.
class FakeLinkActions implements CatalogLinkActions {
  FakeLinkActions({this.canShare = true, this.canOpen = false});

  @override
  final bool canShare;

  @override
  final bool canOpen;

  final List<String> copied = [];
  final List<String> shared = [];
  final List<String> opened = [];

  /// Set to fail the next action — a clipboard refused in an insecure context.
  Object? failure;

  @override
  Future<void> copy(String url) async {
    if (failure != null) throw failure!;
    copied.add(url);
  }

  @override
  Future<void> share(String url, {String? subject}) async {
    if (failure != null) throw failure!;
    shared.add(url);
  }

  @override
  Future<void> open(String url) async {
    if (failure != null) throw failure!;
    opened.add(url);
  }
}
