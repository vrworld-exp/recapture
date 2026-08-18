// lib/domain/entities/catalog.dart
import 'business_profile.dart';
import 'catalog_json.dart';
import 'catalog_status.dart';

/// Headline counts shown on the catalog screen.
class CatalogCounts {
  const CatalogCounts({
    this.products = 0,
    this.archivedProducts = 0,
    this.categories = 0,
  });

  /// Non-archived, non-deleted products — what the grid shows.
  final int products;

  /// Archived products, reachable only through the Archived filter.
  final int archivedProducts;

  final int categories;

  bool get isEmpty => products == 0 && archivedProducts == 0;

  factory CatalogCounts.fromMap(Map<String, dynamic> map) => CatalogCounts(
        products: catalogCount(map['products']),
        archivedProducts: catalogCount(map['archivedProducts']),
        categories: catalogCount(map['categories']),
      );

  Map<String, dynamic> toMap() => {
        'products': products,
        'archivedProducts': archivedProducts,
        'categories': categories,
      };
}

/// The business's storefront — ONE per account (feature 1).
///
/// This is the authoring root the app edits. What customers see is a *projection*
/// of it into Mirage, refreshed only by an explicit publish: nothing on this
/// entity changing means anything to a customer until then (feature 57).
///
/// Two flags carry that split and are worth reading carefully:
///   • [hasUnpublishedChanges] — server-derived from the draft/published revision
///     counters. True from the moment a catalog is created (nothing is live yet),
///     and true again after any edit. It stays true after a PARTIAL publish,
///     because some products really did not make it.
///   • [isPublishing] — a publish run currently holds the catalog. The Publish
///     button is disabled while this is true; a second run would race Mirage's
///     non-atomic writes, and the server answers 409 anyway.
class Catalog {
  const Catalog({
    required this.id,
    required this.name,
    required this.status,
    required this.hasUnpublishedChanges,
    required this.isPublishing,
    required this.isProvisioned,
    this.businessName,
    this.contact,
    this.publicUrl,
    this.lastPublishedAt,
    this.counts = const CatalogCounts(),
    this.updatedAt,
    this.createdAt,
  });

  final String id;

  /// The storefront title customers see.
  final String name;

  final String? businessName;
  final BusinessContact? contact;

  final CatalogStatus status;

  /// The customer-facing catalog URL, or null before the first publish.
  ///
  /// FROZEN server-side once minted: it is what every printed QR encodes, so it
  /// survives renames, republishes and product churn (feature 32). The client
  /// treats it as an opaque string — never parse it, never rebuild it, and never
  /// derive a second URL from it.
  final String? publicUrl;

  /// True once a publish run has provisioned the catalog on Mirage. Implies
  /// [publicUrl] is set, and that the QR is worth printing.
  final bool isProvisioned;

  /// Feature 38 — "Draft changes not yet live". Server-derived; the client must
  /// not try to recompute it by diffing anything.
  final bool hasUnpublishedChanges;

  /// A publish run is in flight right now (feature 36).
  final bool isPublishing;

  final DateTime? lastPublishedAt;
  final CatalogCounts counts;
  final DateTime? updatedAt;
  final DateTime? createdAt;

  /// Nothing has ever gone live and nothing is queued — the first-run empty
  /// state, as opposed to a catalog that was published and then emptied.
  bool get isNeverPublished => lastPublishedAt == null;

  /// Whether a Publish press is worth offering right now. The server re-checks
  /// all of this (an empty catalog is refused with CATALOG_EMPTY); this is only
  /// to avoid a pointless round trip.
  bool get canPublish => !isPublishing && counts.products > 0;

  /// Defensive parsing — every field falls back to a safe value so a malformed
  /// or newer response renders instead of crashing the catalog screen.
  factory Catalog.fromMap(Map<String, dynamic> map) {
    final rawContact = map['contact'];
    final rawCounts = map['counts'];
    return Catalog(
      id: (map['id'] ?? '').toString(),
      name: catalogText(map['name']) ?? 'Untitled catalog',
      businessName: catalogText(map['businessName']),
      contact: rawContact is Map<String, dynamic>
          ? BusinessContact.fromMap(rawContact)
          : null,
      status: CatalogStatusX.fromApiValue((map['status'] ?? '').toString()),
      publicUrl: catalogText(map['publicUrl']),
      isProvisioned: map['isProvisioned'] == true,
      // Absent means "we cannot tell" → assume there ARE unpublished changes.
      // Wrongly hiding the badge tells the user their edits are live when they
      // are not; wrongly showing it costs one redundant publish.
      hasUnpublishedChanges: map['hasUnpublishedChanges'] != false,
      isPublishing: map['isPublishing'] == true,
      lastPublishedAt: catalogDate(map['lastPublishedAt']),
      counts: rawCounts is Map<String, dynamic>
          ? CatalogCounts.fromMap(rawCounts)
          : const CatalogCounts(),
      updatedAt: catalogDate(map['updatedAt']),
      createdAt: catalogDate(map['createdAt']),
    );
  }

  /// Serialises to the same shape [Catalog.fromMap] reads, for warm-start
  /// caching. Server-truth still wins on every screen open — the catalog and its
  /// publish state can change from another device (edge case 5).
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'businessName': businessName,
        'contact': contact?.toMap(),
        'status': status.apiValue,
        'publicUrl': publicUrl,
        'isProvisioned': isProvisioned,
        'hasUnpublishedChanges': hasUnpublishedChanges,
        'isPublishing': isPublishing,
        'lastPublishedAt': lastPublishedAt?.toIso8601String(),
        'counts': counts.toMap(),
        'updatedAt': updatedAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };

  Catalog copyWith({
    String? name,
    String? businessName,
    BusinessContact? contact,
    CatalogStatus? status,
    bool? hasUnpublishedChanges,
    bool? isPublishing,
    CatalogCounts? counts,
    DateTime? updatedAt,
  }) =>
      Catalog(
        id: id,
        name: name ?? this.name,
        businessName: businessName ?? this.businessName,
        contact: contact ?? this.contact,
        status: status ?? this.status,
        // publicUrl and isProvisioned are deliberately NOT copyWith-able: they
        // are minted once by the server and every printed QR depends on the
        // former never moving (feature 32).
        publicUrl: publicUrl,
        isProvisioned: isProvisioned,
        hasUnpublishedChanges: hasUnpublishedChanges ?? this.hasUnpublishedChanges,
        isPublishing: isPublishing ?? this.isPublishing,
        lastPublishedAt: lastPublishedAt,
        counts: counts ?? this.counts,
        updatedAt: updatedAt ?? this.updatedAt,
        createdAt: createdAt,
      );
}
