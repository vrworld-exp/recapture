// lib/domain/catalog/menu_import.dart
//
// Menu import from photos / PDF (more-customization Stage 13.1), as the API
// returns it. The server reads the pages and cleans the draft; this side edits
// the draft and sends the reviewed list back to apply.

String _s(Object? v) => v is String ? v : '';
double? _n(Object? v) => v is num ? v.toDouble() : null;

enum MenuImportStatus {
  uploading,
  processing,
  ready,
  failed,
  applied,
  undone;

  static MenuImportStatus fromApi(String? v) => switch (v) {
        'UPLOADING' => uploading,
        'PROCESSING' => processing,
        'READY' => ready,
        'APPLIED' => applied,
        'UNDONE' => undone,
        _ => failed,
      };
}

/// Below this the review screen highlights the row: "check this one".
const double kLowConfidence = 0.7;

class DraftVariant {
  const DraftVariant(this.label, this.price);
  final String label;
  final double price;
}

class DraftItem {
  DraftItem({
    required this.key,
    required this.name,
    required this.price,
    required this.description,
    required this.foodType,
    required this.confidence,
    required this.variants,
  });

  final String key;
  String name;
  double? price;
  String? description;

  /// VEG | NON_VEG | NONE.
  String foodType;
  final double confidence;
  final List<DraftVariant> variants;

  /// Whether this row is applied at all (unticked rows are skipped).
  bool include = true;

  bool get lowConfidence => confidence < kLowConfidence;

  factory DraftItem.fromMap(Map<String, dynamic> m) => DraftItem(
        key: _s(m['key']),
        name: _s(m['name']),
        price: _n(m['price']),
        description: m['description'] is String ? m['description'] as String : null,
        foodType: _s(m['foodType']).isEmpty ? 'NONE' : _s(m['foodType']),
        confidence: _n(m['confidence']) ?? 0.5,
        variants: [
          for (final v in (m['variants'] is List ? m['variants'] as List : const []))
            if (v is Map && v['label'] is String && v['price'] is num)
              DraftVariant(v['label'] as String, (v['price'] as num).toDouble()),
        ],
      );
}

class DraftCategory {
  DraftCategory({required this.name, required this.items});

  String name;
  final List<DraftItem> items;

  factory DraftCategory.fromMap(Map<String, dynamic> m) => DraftCategory(
        name: _s(m['name']),
        items: [
          for (final i in (m['items'] is List ? m['items'] as List : const []))
            if (i is Map<String, dynamic>) DraftItem.fromMap(i),
        ],
      );
}

/// A dish already on the menu with the same name as a draft row.
class DishMatch {
  const DishMatch({required this.productId, required this.name, this.price});
  final String productId;
  final String name;
  final double? price;
}

class MenuImport {
  const MenuImport({
    required this.id,
    required this.status,
    required this.pages,
    required this.pagesDone,
    required this.categories,
    required this.matches,
    required this.duplicatesDropped,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final MenuImportStatus status;
  final int pages;
  final int pagesDone;
  final List<DraftCategory> categories;

  /// Draft item key → the existing dish it matches.
  final Map<String, DishMatch> matches;
  final List<String> duplicatesDropped;
  final String? errorCode;
  final String? errorMessage;

  factory MenuImport.fromMap(Map<String, dynamic> m) {
    final draft = m['draft'] is Map<String, dynamic> ? m['draft'] as Map<String, dynamic> : null;
    final matches = m['matches'] is Map ? m['matches'] as Map : const {};
    final error = m['error'] is Map ? m['error'] as Map : null;
    return MenuImport(
      id: _s(m['id']),
      status: MenuImportStatus.fromApi(m['status'] as String?),
      pages: m['pages'] is int ? m['pages'] as int : 0,
      pagesDone: m['pagesDone'] is int ? m['pagesDone'] as int : 0,
      categories: [
        for (final c in (draft?['categories'] is List ? draft!['categories'] as List : const []))
          if (c is Map<String, dynamic>) DraftCategory.fromMap(c),
      ],
      matches: {
        for (final e in matches.entries)
          if (e.value is Map)
            e.key as String: DishMatch(
              productId: _s((e.value as Map)['productId']),
              name: _s((e.value as Map)['name']),
              price: _n((e.value as Map)['price']),
            ),
      },
      duplicatesDropped: [
        for (final d in (draft?['duplicatesDropped'] is List ? draft!['duplicatesDropped'] as List : const []))
          if (d is String) d,
      ],
      errorCode: error?['code'] as String?,
      errorMessage: error?['message'] as String?,
    );
  }
}

class ApplyResult {
  const ApplyResult({required this.created, required this.updated, required this.skipped});
  final int created;
  final int updated;
  final int skipped;
}

class DescriptionSuggestion {
  const DescriptionSuggestion({required this.productId, required this.options});
  final String productId;
  final List<String> options;
}

/// `GET …/ai/status`.
class AiStatus {
  const AiStatus({required this.enabled, required this.budgetLeft, required this.tone});
  final bool enabled;
  final bool budgetLeft;

  /// casual | premium | fun.
  final String tone;

  static const off = AiStatus(enabled: false, budgetLeft: false, tone: 'casual');
}
