// lib/domain/catalog/menu_extras.dart
//
// More-customization Stage 7 — the client halves of recapture-api
// `CatalogArBranding`, `CatalogSpotlight`, `CatalogEngagement` and
// `CatalogQrStyle` (models/types/catalog.types.ts). Hand-synced (AGENTS.md §0.1).
//
// Every block parses defensively: an older server sends none of them, which
// reads as "off" — the plain viewer, no carousel, no buttons, a black-on-white QR.
import 'color_contrast.dart';

// ── 3D & AR style ───────────────────────────────────────────────────────────

enum ArStage {
  none('none', 'None'),
  plate('plate', 'Plate'),
  wood('wood', 'Wood'),
  marble('marble', 'Marble'),
  dark('dark', 'Dark');

  const ArStage(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static ArStage parse(Object? raw) =>
      values.firstWhere((v) => v.apiValue == raw, orElse: () => ArStage.none);
}

class ArBranding {
  const ArBranding({
    this.watermarkLogo = false,
    this.logoLoader = false,
    this.stage = ArStage.none,
    this.showDishName = false,
  });

  final bool watermarkLogo;

  /// The restaurant's logo as the viewer's loading ring (`loaderStyle: logo`).
  final bool logoLoader;
  final ArStage stage;
  final bool showDishName;

  static const ArBranding plain = ArBranding();

  bool get isPlain => this == plain;

  factory ArBranding.fromMap(Object? raw) {
    if (raw is! Map) return plain;
    return ArBranding(
      watermarkLogo: raw['watermarkLogo'] == true,
      logoLoader: raw['loaderStyle'] == 'logo',
      stage: ArStage.parse(raw['stage']),
      showDishName: raw['showDishName'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
        'watermarkLogo': watermarkLogo,
        'loaderStyle': logoLoader ? 'logo' : 'default',
        'stage': stage.apiValue,
        'showDishName': showDishName,
      };

  ArBranding copyWith({bool? watermarkLogo, bool? logoLoader, ArStage? stage, bool? showDishName}) =>
      ArBranding(
        watermarkLogo: watermarkLogo ?? this.watermarkLogo,
        logoLoader: logoLoader ?? this.logoLoader,
        stage: stage ?? this.stage,
        showDishName: showDishName ?? this.showDishName,
      );

  @override
  bool operator ==(Object other) =>
      other is ArBranding &&
      other.watermarkLogo == watermarkLogo &&
      other.logoLoader == logoLoader &&
      other.stage == stage &&
      other.showDishName == showDishName;

  @override
  int get hashCode => Object.hash(watermarkLogo, logoLoader, stage, showDishName);
}

// ── Spotlight ───────────────────────────────────────────────────────────────

const int kMaxSpotlightDishes = 6;
const int kMaxSpotlightTitle = 40;
const int kMaxPairings = 4;

class MenuSpotlight {
  const MenuSpotlight({this.enabled = false, this.productIds = const [], this.title});

  final bool enabled;
  final List<String> productIds;
  final String? title;

  static const MenuSpotlight off = MenuSpotlight();

  factory MenuSpotlight.fromMap(Object? raw) {
    if (raw is! Map) return off;
    final ids = raw['productIds'];
    final title = raw['title'];
    return MenuSpotlight(
      enabled: raw['enabled'] == true,
      productIds: ids is List ? ids.whereType<String>().toList() : const [],
      title: title is String && title.trim().isNotEmpty ? title : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'productIds': productIds,
        if ((title ?? '').trim().isNotEmpty) 'title': title!.trim(),
      };
}

// ── Customer buttons ────────────────────────────────────────────────────────

class MenuEngagement {
  const MenuEngagement({
    this.reviewUrl,
    this.whatsappOrder = false,
    this.callWaiter = false,
    this.wifiSsid,
    this.wifiPassword,
    this.feedbackForm = false,
  });

  final String? reviewUrl;
  final bool whatsappOrder;
  final bool callWaiter;
  final String? wifiSsid;
  final String? wifiPassword;
  final bool feedbackForm;

  static const MenuEngagement off = MenuEngagement();

  factory MenuEngagement.fromMap(Object? raw) {
    if (raw is! Map) return off;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    final wifi = raw['wifi'];
    return MenuEngagement(
      reviewUrl: s(raw['reviewUrl']),
      whatsappOrder: raw['whatsappOrder'] == true,
      callWaiter: raw['callWaiter'] == true,
      wifiSsid: wifi is Map ? s(wifi['ssid']) : null,
      wifiPassword: wifi is Map ? s(wifi['password']) : null,
      feedbackForm: raw['feedbackForm'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
        if ((reviewUrl ?? '').trim().isNotEmpty) 'reviewUrl': reviewUrl!.trim(),
        'whatsappOrder': whatsappOrder,
        'callWaiter': callWaiter,
        if ((wifiSsid ?? '').trim().isNotEmpty)
          'wifi': {
            'ssid': wifiSsid!.trim(),
            if ((wifiPassword ?? '').isNotEmpty) 'password': wifiPassword,
          },
        'feedbackForm': feedbackForm,
      };

  /// Same rules as catalogSchemas.ts `engagementSchema`.
  String? validate() {
    final url = (reviewUrl ?? '').trim();
    if (url.isNotEmpty && !url.toLowerCase().startsWith('https://')) {
      return 'The review link must start with https://';
    }
    if ((wifiSsid ?? '').trim().length > 32) return 'The Wi-Fi name is too long.';
    if ((wifiPassword ?? '').length > 63) return 'The Wi-Fi password is too long.';
    return null;
  }
}

// ── Branded QR ──────────────────────────────────────────────────────────────

enum QrTemplate {
  classic('classic', 'Classic', 'The code, your name and the link.'),
  minimal('minimal', 'Minimal', 'Just a big code and your frame text.'),
  bold('bold', 'Bold', 'A band in your menu colour, with your cover photo.'),
  tent('tent', 'Table tent', 'Fold in half — reads from both sides.');

  const QrTemplate(this.apiValue, this.label, this.description);
  final String apiValue;
  final String label;
  final String description;

  static QrTemplate parse(Object? raw) =>
      values.firstWhere((v) => v.apiValue == raw, orElse: () => QrTemplate.classic);
}

const int kMaxQrFrameText = 30;

/// Mirrors MIN_QR_CONTRAST — lower than the text rule, a scanner needs contrast not comfort.
const double kMinQrContrast = 4;

class QrStyle {
  const QrStyle({
    this.fg = '#000000',
    this.bg = '#FFFFFF',
    this.logoCenter = false,
    this.frameText,
    this.template = QrTemplate.classic,
  });

  final String fg;
  final String bg;

  /// The restaurant's own logo in the centre instead of the Mayasabha mark.
  final bool logoCenter;
  final String? frameText;
  final QrTemplate template;

  static const QrStyle plain = QrStyle();

  factory QrStyle.fromMap(Object? raw) {
    if (raw is! Map) return plain;
    String hex(Object? v, String fallback) =>
        v is String && kHexColor.hasMatch(v) ? v.toUpperCase() : fallback;
    final frame = raw['frameText'];
    return QrStyle(
      fg: hex(raw['fg'], '#000000'),
      bg: hex(raw['bg'], '#FFFFFF'),
      logoCenter: raw['logoCenter'] == true,
      frameText: frame is String && frame.trim().isNotEmpty ? frame : null,
      template: QrTemplate.parse(raw['template']),
    );
  }

  Map<String, dynamic> toMap() => {
        'fg': fg.toUpperCase(),
        'bg': bg.toUpperCase(),
        'logoCenter': logoCenter,
        if ((frameText ?? '').trim().isNotEmpty) 'frameText': frameText!.trim(),
        'template': template.apiValue,
      };

  QrStyle copyWith({
    String? fg,
    String? bg,
    bool? logoCenter,
    Object? frameText = _keep,
    QrTemplate? template,
  }) =>
      QrStyle(
        fg: fg ?? this.fg,
        bg: bg ?? this.bg,
        logoCenter: logoCenter ?? this.logoCenter,
        frameText: identical(frameText, _keep) ? this.frameText : frameText as String?,
        template: template ?? this.template,
      );

  /// The API's rules, checked before the round trip: dark on light, far enough apart.
  String? validate() {
    if (!kHexColor.hasMatch(fg) || !kHexColor.hasMatch(bg)) return 'Colours must be #RRGGBB.';
    if (relativeLuminance(fg) >= relativeLuminance(bg)) {
      return 'The code must be darker than its background — inverted codes fail on many phones.';
    }
    if (contrastRatio(fg, bg) < kMinQrContrast) {
      return 'Those colours are too close — phones may not read the code.';
    }
    if ((frameText ?? '').trim().length > kMaxQrFrameText) {
      return 'Keep the frame text to $kMaxQrFrameText characters.';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is QrStyle &&
      other.fg.toUpperCase() == fg.toUpperCase() &&
      other.bg.toUpperCase() == bg.toUpperCase() &&
      other.logoCenter == logoCenter &&
      (other.frameText ?? '') == (frameText ?? '') &&
      other.template == template;

  @override
  int get hashCode =>
      Object.hash(fg.toUpperCase(), bg.toUpperCase(), logoCenter, frameText ?? '', template);
}

// ── Feedback report (analytics) ─────────────────────────────────────────────

class FeedbackEntry {
  const FeedbackEntry({required this.rating, required this.comment, this.at});

  final int rating;
  final String comment;
  final DateTime? at;
}

/// What diners said through the feedback form, for the analytics range.
class FeedbackReport {
  const FeedbackReport({
    this.count = 0,
    this.average,
    this.distribution = const [0, 0, 0, 0, 0],
    this.recent = const [],
  });

  final int count;
  final double? average;

  /// How many 1★ … 5★.
  final List<int> distribution;
  final List<FeedbackEntry> recent;

  static const empty = FeedbackReport();

  factory FeedbackReport.fromMap(Map<String, dynamic>? map) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    final dist = map?['distribution'];
    final recent = map?['recent'];
    return FeedbackReport(
      count: n(map?['count']),
      average: map?['average'] is num ? (map!['average'] as num).toDouble() : null,
      distribution: [
        for (var i = 0; i < 5; i++) dist is List && i < dist.length ? n(dist[i]) : 0,
      ],
      recent: [
        if (recent is List)
          for (final r in recent)
            if (r is Map)
              FeedbackEntry(
                rating: n(r['rating']),
                comment: r['comment'] is String ? r['comment'] as String : '',
                at: r['at'] is String ? DateTime.tryParse(r['at'] as String) : null,
              ),
      ],
    );
  }
}

const Object _keep = Object();

/// Stage 11: "My plate" on the public menu — a list diners show the waiter,
/// never an order. On (with totals) unless the owner switches it off.
class MenuPlate {
  const MenuPlate({this.enabled = true, this.showTotal = true});

  final bool enabled;
  final bool showTotal;

  static const MenuPlate defaults = MenuPlate();

  factory MenuPlate.fromMap(Object? raw) {
    if (raw is! Map) return defaults;
    return MenuPlate(enabled: raw['enabled'] != false, showTotal: raw['showTotal'] != false);
  }

  Map<String, dynamic> toMap() => {'enabled': enabled, 'showTotal': showTotal};

  MenuPlate copyWith({bool? enabled, bool? showTotal}) =>
      MenuPlate(enabled: enabled ?? this.enabled, showTotal: showTotal ?? this.showTotal);
}

// ── Stage 12 ─────────────────────────────────────────────────────────────────

/// The Google "write a review" link for a Place ID (`ChIJ…`), or the input
/// unchanged when it is already a link. Null when it is neither. (12.1)
String? googleReviewLinkFrom(String input) {
  final value = input.trim();
  if (RegExp(r'^ChIJ[\w-]{10,}$').hasMatch(value)) {
    return 'https://search.google.com/local/writereview?placeid=$value';
  }
  return isGoogleReviewLink(value) ? value : null;
}

/// https on google.com / google.co.in / g.page / goo.gl — the server's rule.
bool isGoogleReviewLink(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  const hosts = ['google.com', 'google.co.in', 'g.page', 'goo.gl', 'maps.app.goo.gl'];
  return hosts.any((h) => host == h || host.endsWith('.$h'));
}

/// Google's own tool for finding a business's Place ID.
const kPlaceIdFinderUrl = 'https://developers.google.com/maps/documentation/places/web-service/place-id';

enum DeliveryPlatform {
  zomato('zomato', 'Zomato', ['zomato.com']),
  swiggy('swiggy', 'Swiggy', ['swiggy.com']),
  magicpin('magicpin', 'magicpin', ['magicpin.in']),
  eazydiner('eazydiner', 'EazyDiner', ['eazydiner.com']),
  dineout('dineout', 'Dineout', ['dineout.co.in', 'swiggy.com']);

  const DeliveryPlatform(this.key, this.label, this.hosts);
  final String key;
  final String label;
  final List<String> hosts;

  /// https on this platform's own domain — the server refuses anything else.
  bool accepts(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return hosts.any((h) => host == h || host.endsWith('.$h'));
  }
}

enum BookingType {
  whatsapp('WHATSAPP', 'WhatsApp message'),
  phone('PHONE', 'Phone call'),
  url('URL', 'Booking website');

  const BookingType(this.apiValue, this.label);
  final String apiValue;
  final String label;
}

/// Delivery and booking links on the menu (12.3). Empty = nothing shown.
class MenuLinks {
  const MenuLinks({this.delivery = const {}, this.bookingType, this.bookingValue});

  final Map<DeliveryPlatform, String> delivery;
  final BookingType? bookingType;
  final String? bookingValue;

  static const none = MenuLinks();

  bool get isEmpty => delivery.isEmpty && bookingType == null;

  factory MenuLinks.fromMap(Object? raw) {
    if (raw is! Map) return none;
    final booking = raw['booking'];
    BookingType? type;
    String? value;
    if (booking is Map && booking['value'] is String) {
      type = BookingType.values.where((t) => t.apiValue == booking['type']).firstOrNull;
      value = booking['value'] as String;
    }
    return MenuLinks(
      delivery: {
        for (final p in DeliveryPlatform.values)
          if (raw[p.key] is String && (raw[p.key] as String).isNotEmpty) p: raw[p.key] as String,
      },
      bookingType: type,
      bookingValue: type == null ? null : value,
    );
  }

  /// The PATCH value — null clears every link.
  Map<String, dynamic>? toMap() => isEmpty
      ? null
      : {
          for (final e in delivery.entries) e.key.key: e.value,
          if (bookingType != null && (bookingValue ?? '').trim().isNotEmpty)
            'booking': {'type': bookingType!.apiValue, 'value': bookingValue!.trim()},
        };
}
