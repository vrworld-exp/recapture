// lib/domain/entities/business_profile.dart
import 'catalog_json.dart';

/// Maximum lengths, mirrored from the backend Zod bounds (`catalogSchemas.ts`)
/// so the form rejects an over-long value before a round trip instead of after
/// a 400.
const int kMaxBusinessNameLength = 120;
const int kMaxCatalogNameLength = 120;

/// Social handles/links on a business profile.
///
/// ⚠ ReCapture-only — Mirage's restaurant schema has no social fields, so none
/// of these reach the public catalog. [BusinessProfile.publicFields] is what the
/// UI marks from; do not hardcode that judgement here.
class BusinessSocials {
  const BusinessSocials({
    this.instagram,
    this.facebook,
    this.youtube,
    this.whatsapp,
  });

  final String? instagram;
  final String? facebook;
  final String? youtube;
  final String? whatsapp;

  bool get isEmpty =>
      instagram == null && facebook == null && youtube == null && whatsapp == null;

  /// Field-by-field, never a spread — an unknown key from a newer server is
  /// ignored rather than carried into a write that would then be rejected.
  factory BusinessSocials.fromMap(Map<String, dynamic> map) => BusinessSocials(
        instagram: catalogText(map['instagram']),
        facebook: catalogText(map['facebook']),
        youtube: catalogText(map['youtube']),
        whatsapp: catalogText(map['whatsapp']),
      );

  /// Only non-null fields are emitted: the backend schema is `.strict()` and
  /// treats a present key as an intent to set it.
  Map<String, dynamic> toMap() => {
        if (instagram != null) 'instagram': instagram,
        if (facebook != null) 'facebook': facebook,
        if (youtube != null) 'youtube': youtube,
        if (whatsapp != null) 'whatsapp': whatsapp,
      };

  BusinessSocials copyWith({
    String? instagram,
    String? facebook,
    String? youtube,
    String? whatsapp,
  }) =>
      BusinessSocials(
        instagram: instagram ?? this.instagram,
        facebook: facebook ?? this.facebook,
        youtube: youtube ?? this.youtube,
        whatsapp: whatsapp ?? this.whatsapp,
      );
}

/// How customers reach the business.
///
/// Only [phone] and [address] reach the public catalog (Mirage carries them as
/// `phoneNo` and `location`); [email], [website] and [socials] are
/// ReCapture-only. Again — read that from [BusinessProfile.publicFields], which
/// the server owns, rather than restating it in the UI.
///
/// PATCH semantics: the backend REPLACES the whole contact block when the key is
/// present, so a partial map clears the fields it omits. Editors must send the
/// full block (that is also what makes "clear my website" possible at all).
class BusinessContact {
  const BusinessContact({
    this.phone,
    this.email,
    this.address,
    this.website,
    this.socials,
  });

  final String? phone;
  final String? email;
  final String? address;
  final String? website;
  final BusinessSocials? socials;

  bool get isEmpty =>
      phone == null &&
      email == null &&
      address == null &&
      website == null &&
      (socials?.isEmpty ?? true);

  factory BusinessContact.fromMap(Map<String, dynamic> map) {
    final rawSocials = map['socials'];
    return BusinessContact(
      phone: catalogText(map['phone']),
      email: catalogText(map['email']),
      address: catalogText(map['address']),
      website: catalogText(map['website']),
      socials: rawSocials is Map<String, dynamic>
          ? BusinessSocials.fromMap(rawSocials)
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
        if (address != null) 'address': address,
        if (website != null) 'website': website,
        if (socials != null && !socials!.isEmpty) 'socials': socials!.toMap(),
      };

  BusinessContact copyWith({
    String? phone,
    String? email,
    String? address,
    String? website,
    BusinessSocials? socials,
  }) =>
      BusinessContact(
        phone: phone ?? this.phone,
        email: email ?? this.email,
        address: address ?? this.address,
        website: website ?? this.website,
        socials: socials ?? this.socials,
      );
}

/// The business profile behind the storefront (features 58-60).
///
/// A VIEW of the catalog document, not a separate record: editing it is an
/// authoring change like any other and lights up "Draft changes not yet live".
class BusinessProfile {
  const BusinessProfile({
    required this.id,
    required this.name,
    required this.publicFields,
    this.businessName,
    this.contact,
    this.logoUrl,
    this.coverImageUrl,
    this.updatedAt,
  });

  /// The catalog this profile belongs to.
  final String id;

  /// The storefront title — becomes the public catalog's name on publish.
  final String name;

  final String? businessName;
  final BusinessContact? contact;

  /// CDN URLs derived server-side from stored S3 keys. Null until an upload has
  /// been committed; the client never builds these itself.
  final String? logoUrl;
  final String? coverImageUrl;

  /// Dotted paths (`name`, `contact.phone`, `contact.address`, `logoUrl`, …) of
  /// the fields that actually reach the published public catalog.
  ///
  /// SERVER-OWNED on purpose: which fields Mirage carries is a property of the
  /// publish worker, so hardcoding the list here would silently go stale the
  /// first time the worker learns to carry another one. The profile screen marks
  /// everything NOT in this list as ReCapture-only.
  final List<String> publicFields;

  final DateTime? updatedAt;

  /// Whether [fieldPath] reaches customers once published.
  bool isPublic(String fieldPath) => publicFields.contains(fieldPath);

  /// Defensive parsing — every field falls back to a safe value so a malformed
  /// or newer response renders instead of crashing the profile screen.
  factory BusinessProfile.fromMap(Map<String, dynamic> map) {
    final rawContact = map['contact'];
    final rawPublic = map['publicFields'];
    return BusinessProfile(
      id: (map['id'] ?? '').toString(),
      name: catalogText(map['name']) ?? '',
      businessName: catalogText(map['businessName']),
      contact: rawContact is Map<String, dynamic>
          ? BusinessContact.fromMap(rawContact)
          : null,
      logoUrl: catalogText(map['logoUrl']),
      coverImageUrl: catalogText(map['coverImageUrl']),
      // An absent list means "we know of nothing public" — the UI then marks
      // everything ReCapture-only, which understates rather than overpromises.
      publicFields: catalogStringList(rawPublic),
      updatedAt: catalogDate(map['updatedAt']),
    );
  }

  BusinessProfile copyWith({
    String? name,
    String? businessName,
    BusinessContact? contact,
    String? logoUrl,
    String? coverImageUrl,
  }) =>
      BusinessProfile(
        id: id,
        name: name ?? this.name,
        businessName: businessName ?? this.businessName,
        contact: contact ?? this.contact,
        logoUrl: logoUrl ?? this.logoUrl,
        coverImageUrl: coverImageUrl ?? this.coverImageUrl,
        publicFields: publicFields,
        updatedAt: updatedAt,
      );
}
