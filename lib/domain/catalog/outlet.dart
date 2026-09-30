// Stage 16 — multi-branch restaurants: one owner, a main outlet and branches.
//
// A branch is an ordinary catalog (own page, QR standees, subscription, stock)
// whose menu and look follow the main outlet. The app picks which outlet it is
// editing and sends it as the `X-Outlet-Id` header on every /catalog call.

/// Which outlet the current catalog is, when the restaurant has branches.
/// Null on [Catalog.outlet] for a standalone restaurant (everyone before 16).
class CatalogOutletInfo {
  const CatalogOutletInfo({
    required this.isBranch,
    this.outletName,
    this.mainCatalogId,
  });

  final bool isBranch;
  final String? outletName;
  final String? mainCatalogId;

  static CatalogOutletInfo? fromMapOrNull(Object? raw) {
    if (raw is! Map) return null;
    return CatalogOutletInfo(
      isBranch: raw['role'] == 'BRANCH',
      outletName: raw['outletName']?.toString(),
      mainCatalogId: raw['mainCatalogId']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'role': isBranch ? 'BRANCH' : 'MAIN',
        'outletName': outletName,
        'mainCatalogId': mainCatalogId,
      };
}

/// One row of GET /catalog/outlets.
class Outlet {
  const Outlet({
    required this.id,
    required this.isMain,
    required this.name,
    this.outletName,
    this.status = '',
    this.hasUnpublishedChanges = false,
    this.publicUrl,
  });

  final String id;
  final bool isMain;
  final String name;
  final String? outletName;
  final String status;
  final bool hasUnpublishedChanges;
  final String? publicUrl;

  /// "Koregaon Park", or "Main outlet" for a main outlet with no label.
  String get label =>
      (outletName != null && outletName!.trim().isNotEmpty)
          ? outletName!
          : (isMain ? 'Main outlet' : name);

  factory Outlet.fromMap(Map<String, dynamic> map) => Outlet(
        id: (map['id'] ?? '').toString(),
        isMain: map['role'] != 'BRANCH',
        name: (map['name'] ?? '').toString(),
        outletName: map['outletName']?.toString(),
        status: (map['status'] ?? '').toString(),
        hasUnpublishedChanges: map['hasUnpublishedChanges'] == true,
        publicUrl: map['publicUrl']?.toString(),
      );
}

/// A branch dish that follows the main outlet; [overriddenFields] are the ones
/// this outlet changed itself.
class BranchLink {
  const BranchLink({this.overriddenFields = const []});

  final List<String> overriddenFields;

  bool overrides(String field) => overriddenFields.contains(field);

  static BranchLink? fromMapOrNull(Object? raw) {
    if (raw is! Map || raw['followsMain'] != true) return null;
    final fields = raw['overriddenFields'];
    return BranchLink(
      overriddenFields:
          fields is List ? fields.map((e) => e.toString()).toList() : const [],
    );
  }

  Map<String, dynamic> toMap() =>
      {'followsMain': true, 'overriddenFields': overriddenFields};
}

/// One outlet's result of "Publish all outlets".
class PublishAllResult {
  const PublishAllResult({
    required this.outletId,
    required this.outcome,
    this.outletName,
  });

  final String outletId;
  final String? outletName;
  final String outcome;

  bool get ok => outcome == 'QUEUED' || outcome == 'NOTHING_TO_PUBLISH';

  factory PublishAllResult.fromMap(Map<String, dynamic> map) => PublishAllResult(
        outletId: (map['outletId'] ?? '').toString(),
        outletName: map['outletName']?.toString(),
        outcome: (map['outcome'] ?? '').toString(),
      );
}
