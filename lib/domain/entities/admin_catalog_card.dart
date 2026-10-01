// lib/domain/entities/admin_catalog_card.dart
//
// One card on the ADMIN's "All catalogs" grid — `GET /admin/catalogs`.
//
// Deliberately small: what an admin needs to RECOGNISE a restaurant (its name,
// its logo, whether it is a branch, whether someone left edits unpublished).
// Opening a card goes through the /rep surface, which carries everything else.
library;

import '../catalog/catalog_names.dart';

class AdminCatalogCard {
  const AdminCatalogCard({
    required this.id,
    required this.name,
    this.businessName,
    this.logoUrl,
    this.publicUrl,
    this.isBranch = false,
    this.isLive = true,
    this.isPublishing = false,
    this.hasDraftChanges = false,
    this.lastPublishedAt,
  });

  final String id;

  /// The stored slug. Print [displayName], never this (AGENTS.md §Catalog names).
  final String name;
  final String? businessName;
  final String? logoUrl;
  final String? publicUrl;
  final bool isBranch;

  /// Live (PUBLISHED) vs taken offline (UNPUBLISHED).
  final bool isLive;

  /// A publish or unpublish is running — the live/offline answer is about to
  /// change, so the card says so rather than a status that may be stale.
  final bool isPublishing;
  final bool hasDraftChanges;
  final DateTime? lastPublishedAt;

  String get displayName => catalogDisplayName(name);

  /// Null for a row the client cannot use (no id) — dropped, never rendered as
  /// a card that opens nothing.
  static AdminCatalogCard? fromMap(Map<String, dynamic> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) return null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    return AdminCatalogCard(
      id: id,
      name: text(map['name']) ?? '',
      businessName: text(map['businessName']),
      logoUrl: text(map['logoUrl']),
      publicUrl: text(map['publicUrl']),
      isBranch: map['isBranch'] == true,
      // Anything but an explicit UNPUBLISHED reads as live: the server lists
      // nothing else, and an older server sent no status at all.
      isLive: map['status'] != 'UNPUBLISHED',
      isPublishing: map['isPublishing'] == true,
      hasDraftChanges: map['hasDraftChanges'] == true,
      lastPublishedAt: DateTime.tryParse(text(map['lastPublishedAt']) ?? ''),
    );
  }
}

/// One page of the grid.
class AdminCatalogPage {
  const AdminCatalogPage({required this.items, required this.nextCursor});

  final List<AdminCatalogCard> items;
  final String? nextCursor;
}
