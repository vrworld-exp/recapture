// lib/domain/catalog/catalog_scope.dart
//
// WHOSE catalog a screen is acting on.
//
// There are exactly two answers and they are not symmetric. An OWNER has one
// catalog and never names it — `/catalog/...` means "mine", resolved from the
// token. A REP acts on a restaurant's catalog and must name it every time, and
// the server re-checks the delegation on every request.
//
// This type exists so the difference is a VALUE a screen can be handed rather
// than a fork in the widget tree. The business profile is the same seven fields,
// the same validators, the same two-step branding upload and the same "nothing
// here is live until you publish" promise whether the person typing owns the
// restaurant or is standing in it with a standee — so it is one screen, given a
// scope, rather than two screens that drift.
//
// Pure Dart, no Flutter import, like every other file under domain/. It is also
// a Riverpod family key, which is why the equality below is written out: two
// `CatalogScope.delegated('abc')` values must be the SAME provider, or a screen
// would re-fetch and lose its form on every rebuild.
library;

class CatalogScope {
  /// The signed-in user's own catalog. Resolved from the token server-side;
  /// there is no id to carry.
  const CatalogScope.owner() : delegatedCatalogId = null;

  /// A restaurant's catalog the caller holds a delegation on.
  const CatalogScope.delegated(String catalogId)
      : delegatedCatalogId = catalogId;

  /// The catalog id, or null for [CatalogScope.owner].
  final String? delegatedCatalogId;

  bool get isDelegated => delegatedCatalogId != null;

  /// The API prefix every scoped route hangs off.
  ///
  /// The two route groups are a deliberate MIRROR of each other — `/catalog/x`
  /// and `/rep/catalogs/:id/x` for the same `x` — which is what lets one string
  /// stand in for the whole difference. When you add a route to one side, add
  /// the matching one to the other or this abstraction quietly becomes a lie.
  String get basePath => delegatedCatalogId == null
      ? '/catalog'
      : '/rep/catalogs/$delegatedCatalogId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogScope &&
          other.delegatedCatalogId == delegatedCatalogId;

  @override
  int get hashCode => delegatedCatalogId.hashCode;

  @override
  String toString() => delegatedCatalogId == null
      ? 'CatalogScope.owner()'
      : 'CatalogScope.delegated($delegatedCatalogId)';
}
