// lib/data/repositories/standee_sheet.dart
//
// ONE code, printed several times — the types both doors to the single-standee
// sheet share (`AdminStandeeRepository.standeeSheet` for any code, and
// `RepRepository.standeeSheet` for a code the rep holds).
//
// Hand-synced with `recapture-api/src/services/standeeSheetService.ts`
// (`SingleStandeeLayout`, `StandeeSheetPlan`, `singleStandeePages`) and the
// `X-Standee-Sheet-*` headers — there is no shared package, per AGENTS.md §0.1.
import '../../application/catalog/qr_download_file.dart';
import 'admin_standee_repository.dart' show kStandeeSheetMaxCopiesFallback;

/// How one code's copies are laid out on paper.
///
/// TWO LAYOUTS BECAUSE THEY ARE TWO PHYSICAL OBJECTS. [single] is the one-up
/// sheet — one big square per A4 page — which is a table stand; [grid] is the
/// batch sheet's layout (nine 1.67in cards to a page by default, with cut
/// guides) which is a sticker-sized cutout. Both draw the same square.
enum StandeeSheetLayout {
  /// One QR per page. `copies` is the page count.
  single,

  /// The batch grid, `copies` cards of this one code, side by side.
  grid;

  String get apiValue => name;

  /// What the dialog calls it.
  String get label => switch (this) {
        StandeeSheetLayout.single => '1 QR per page',
        StandeeSheetLayout.grid => 'Grid of QRs per page',
      };
}

/// What one code's sheet would take, read before the download.
///
/// The grid's per-page count is the SERVER's — env-tuned and clamped to what
/// A4 holds — so "10 copies on the grid is 2 pages" cannot be said without
/// asking. [maxCopies] travels with it so the field's ceiling is the server's.
class StandeeSheetPlan {
  const StandeeSheetPlan({
    required this.columns,
    required this.rows,
    required this.perPage,
    required this.maxCopies,
  });

  final int columns;
  final int rows;

  /// Cards one A4 page holds on the [StandeeSheetLayout.grid] layout.
  final int perPage;
  final int maxCopies;

  /// Pages for [copies] in [layout] — THE SAME ARITHMETIC as the server's
  /// `singleStandeePages`, so the number in the dialog is the number of pages
  /// that come out of the printer.
  int pagesFor(int copies, StandeeSheetLayout layout) {
    if (copies < 1) return 0;
    return switch (layout) {
      StandeeSheetLayout.single => copies,
      StandeeSheetLayout.grid =>
        perPage < 1 ? 0 : (copies + perPage - 1) ~/ perPage,
    };
  }

  factory StandeeSheetPlan.fromMap(Map<String, dynamic> map) {
    int read(String key, [int fallback = 0]) =>
        (map[key] as num?)?.toInt() ?? fallback;
    return StandeeSheetPlan(
      columns: read('columns'),
      rows: read('rows'),
      perPage: read('perPage'),
      maxCopies: read('maxCopies', kStandeeSheetMaxCopiesFallback),
    );
  }
}

/// One code's printable sheet, and what the server says is in it.
///
/// The counts arrive as `X-Standee-Sheet-*` RESPONSE HEADERS because the body
/// is the PDF. Both default rather than being demanded: a proxy that strips
/// them must not turn a good download into an error.
class StandeeSheetDownload {
  const StandeeSheetDownload({
    required this.file,
    required this.copies,
    required this.pages,
  });

  final QrDownloadFile file;

  /// Times the code was printed — what was asked for, unless the server said
  /// otherwise.
  final int copies;

  /// Zero when the header did not arrive; the notice then drops the clause.
  final int pages;
}

/// The confirmation after one code's sheet is saved.
///
/// Names the copies when there are more than one and the pages when they are
/// known — "Standee ABCD2345 saved" is what the plain sheet always said, and it
/// still is for one copy.
String standeeSheetNotice(String code, StandeeSheetDownload sheet) {
  if (sheet.copies <= 1) return 'Standee $code saved.';
  final pages = sheet.pages == 0
      ? ''
      : sheet.pages == 1
          ? ' on 1 page'
          : ' over ${sheet.pages} pages';
  return 'Standee $code saved — ${sheet.copies} copies$pages.';
}
