// lib/domain/entities/rep_activation.dart
import 'catalog_json.dart';
import 'catalog_status.dart';

/// What a rep is asking for when they activate a standee.
///
/// [restaurantPhone] is E.164 and it is THE HIGHEST-CONSEQUENCE FIELD IN THE
/// APP. It becomes the restaurant's account identity: they later sign in with
/// exactly this number, and the backend finds the account this activation
/// created. A typo does not produce an error anywhere — it produces a real
/// account for a number nobody owns, permanently holding a catalog slot, while
/// the actual restaurant signs in on the right number and gets an empty second
/// account with their catalog stranded behind the typo.
///
/// Which is why the screen that builds this confirms the number back to the rep
/// before submitting, and why it must be composed with the SAME validator the
/// OTP sign-in screen uses rather than a similar one.
class RepActivationRequest {
  const RepActivationRequest({
    required this.code,
    required this.restaurantName,
    required this.restaurantPhone,
    this.businessName,
  });

  /// Already normalised by [QrCodeInput.normalize].
  final String code;
  final String restaurantName;

  /// E.164, dial code included — `+919876543210`.
  final String restaurantPhone;

  final String? businessName;

  Map<String, dynamic> toJson() => {
        'code': code,
        'restaurantName': restaurantName,
        'restaurantPhone': restaurantPhone,
        if (businessName != null && businessName!.trim().isNotEmpty)
          'businessName': businessName!.trim(),
      };
}

/// How an activation ended, as the server reports it.
///
/// [alreadyActive] is a SUCCESS, not a conflict: it is what a re-run of an
/// activation that already worked returns — the rep tapped twice, or the first
/// attempt died after the code was claimed. The screen treats it exactly like
/// [activated], because for the rep standing at the table the outcome is
/// identical: this standee now points at this restaurant.
enum RepActivationOutcome { activated, alreadyActive }

/// A live standee and the catalog behind it.
class RepActivation {
  const RepActivation({
    required this.outcome,
    required this.catalogId,
    required this.publicUrl,
  });

  final RepActivationOutcome outcome;
  final String catalogId;

  /// The frozen standee URL. Shown on the success screen so the rep can check
  /// the sticker they are about to leave on a table actually resolves.
  final String publicUrl;

  factory RepActivation.fromMap(Map<String, dynamic> map) => RepActivation(
        outcome: (catalogText(map['outcome']) ?? '').toUpperCase() ==
                'ALREADY_ACTIVE'
            ? RepActivationOutcome.alreadyActive
            : RepActivationOutcome.activated,
        catalogId: catalogText(map['catalogId']) ?? '',
        publicUrl: catalogText(map['publicUrl']) ?? '',
      );
}

/// One catalog a rep may currently act on.
///
/// Deliberately smaller than the owner's `Catalog`: a rep's list is a picker,
/// and the counts the owner DTO carries cost a query each. The full picture
/// comes from the screens that act on one catalog.
class RepCatalogSummary {
  const RepCatalogSummary({
    required this.id,
    required this.name,
    required this.status,
    this.businessName,
    this.publicUrl,
    this.isProvisioned = false,
    this.grantedAt,
  });

  final String id;
  final String name;
  final String? businessName;
  final CatalogStatus status;

  /// The standee URL, once activation has frozen one.
  final String? publicUrl;

  /// Whether the catalog has reached the public menu host yet. A rep-activated
  /// catalog is NOT provisioned until its first publish, which is normal for
  /// the first minutes of a visit rather than a problem to report.
  final bool isProvisioned;

  final DateTime? grantedAt;

  /// What the rep should see under the name.
  String get displayName {
    final business = businessName?.trim();
    return business == null || business.isEmpty ? name : business;
  }

  factory RepCatalogSummary.fromMap(Map<String, dynamic> map) =>
      RepCatalogSummary(
        id: catalogText(map['id']) ?? '',
        name: catalogText(map['name']) ?? 'Untitled catalog',
        businessName: catalogText(map['businessName']),
        status: CatalogStatusX.fromApiValue(
          (map['status'] ?? '').toString(),
        ),
        publicUrl: catalogText(map['publicUrl']),
        isProvisioned: map['isProvisioned'] == true,
        grantedAt: catalogDate(map['grantedAt']),
      );
}
