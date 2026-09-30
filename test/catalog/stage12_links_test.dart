// Stage 12 (more-customization): the review-link helper and the delivery host rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/menu_extras.dart';

void main() {
  group('googleReviewLinkFrom', () {
    test('turns a Place ID into the direct review link', () {
      expect(
        googleReviewLinkFrom('ChIJN1t_tDeuEmsRUsoyG83frY4'),
        'https://search.google.com/local/writereview?placeid=ChIJN1t_tDeuEmsRUsoyG83frY4',
      );
    });

    test('keeps a Google link, refuses anything else', () {
      expect(googleReviewLinkFrom('https://g.page/r/abc/review'), 'https://g.page/r/abc/review');
      expect(googleReviewLinkFrom('https://www.zomato.com/cafe/reviews'), isNull);
      expect(googleReviewLinkFrom('http://g.page/r/abc'), isNull);
    });
  });

  test('delivery links must be https on the platform domain', () {
    expect(DeliveryPlatform.zomato.accepts('https://www.zomato.com/pune/cafe'), isTrue);
    expect(DeliveryPlatform.zomato.accepts('https://zomato.com.evil.io/x'), isFalse);
    expect(DeliveryPlatform.swiggy.accepts('http://www.swiggy.com/x'), isFalse);
  });

  test('links round-trip and empty clears', () {
    final links = MenuLinks.fromMap({
      'zomato': 'https://www.zomato.com/pune/cafe',
      'booking': {'type': 'WHATSAPP', 'value': '9876543210'},
    });
    expect(links.delivery.keys, [DeliveryPlatform.zomato]);
    expect(links.toMap(), {
      'zomato': 'https://www.zomato.com/pune/cafe',
      'booking': {'type': 'WHATSAPP', 'value': '9876543210'},
    });
    expect(MenuLinks.none.toMap(), isNull);
  });
}
