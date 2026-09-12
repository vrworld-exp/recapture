// lib/domain/entities/standee_activation.dart
//
// What a standee in use turned INTO — the restaurant it activated and who
// activated it. The read behind the admin's QR button on an "in use" row
// (`GET /admin/qr-codes/:code/activation`).
//
// The person is a [ProjectOwnerSummary], the same list-safe shape the "Created
// by" label on a live project uses: a name and whether there is a picture.
// The raw phone or email an admin dials is fetched on demand through the same
// bounded route that label taps through to (`GET /admin/users/:id`) — this
// entity deliberately cannot carry a contact identifier.
import '../catalog/catalog_names.dart';
import 'catalog_json.dart';
import 'catalog_status.dart';
import 'project_owner.dart';

/// The restaurant behind an activated standee, as the QR screen shows it.
class StandeeActivationCatalog {
  const StandeeActivationCatalog({
    required this.id,
    required this.name,
    required this.status,
    this.businessName,
    this.publicUrl,
  });

  final String id;

  /// The stored slug — `spice_garden`. See [displayName].
  final String name;

  final String? businessName;
  final CatalogStatus status;

  /// The link to show and to draw — the Mirage page — or null while the
  /// restaurant has been activated but never published. Displayed VERBATIM.
  final String? publicUrl;

  /// The name as a person reads it: the business name where one is set,
  /// otherwise the slug de-slugged — the same rule the rep's list uses.
  String get displayName {
    final business = businessName?.trim();
    return business == null || business.isEmpty
        ? catalogDisplayName(name)
        : business;
  }

  static StandeeActivationCatalog fromMap(Map<String, dynamic> map) =>
      StandeeActivationCatalog(
        id: catalogText(map['id']) ?? '',
        name: catalogText(map['name']) ?? 'Untitled catalog',
        businessName: catalogText(map['businessName']),
        status: CatalogStatusX.fromApiValue((map['status'] ?? '').toString()),
        publicUrl: catalogText(map['publicUrl']),
      );
}

class StandeeActivation {
  const StandeeActivation({
    required this.code,
    required this.catalog,
    this.activatedAt,
    this.activatedBy,
  });

  final String code;
  final StandeeActivationCatalog catalog;
  final DateTime? activatedAt;

  /// Null when the activating account no longer resolves.
  final ProjectOwnerSummary? activatedBy;

  static StandeeActivation fromMap(Map<String, dynamic> map) {
    final catalog = map['catalog'];
    return StandeeActivation(
      code: catalogText(map['code']) ?? '',
      catalog: StandeeActivationCatalog.fromMap(
        catalog is Map<String, dynamic> ? catalog : const {},
      ),
      activatedAt: catalogDate(map['activatedAt']),
      activatedBy: ProjectOwnerSummary.tryFrom(map['activatedBy']),
    );
  }
}
