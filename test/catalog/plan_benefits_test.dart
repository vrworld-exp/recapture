// The plan cards' ✓ / ✗ rows: every plan lists every row, and what is ticked
// follows the plan (customization rule, server feature keys, caps).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/plan_benefits.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/presentation/widgets/catalog/plan_comparison_sheet.dart';

PlanDefinition _plan(PlanId id, {int threeD = 10, int standees = 1, List<String> features = const []}) =>
    PlanDefinition(
      planId: id,
      displayName: id.name,
      priceMonthlyPaise: 100000,
      yearlyDiscountPct: 0,
      threeDDishCap: threeD,
      includedStandeeCount: standees,
      features: features,
    );

Map<String, bool> _ticks(PlanDefinition p) => {for (final b in planBenefits(p)) b.id: b.included};

void main() {
  test('every plan lists the same rows in the same order', () {
    final ids = [
      for (final id in [PlanId.taste, PlanId.signature, PlanId.masterchef])
        planBenefits(_plan(id)).map((b) => b.id).toList(),
    ];
    expect(ids[1], ids[0]);
    expect(ids[2], ids[0]);
  });

  test('Taste: the basics ticked, every customization row crossed', () {
    final t = _ticks(_plan(PlanId.taste));
    expect(t['threeD'], isTrue);
    expect(t['images'], isTrue);
    for (final id in ['themes', 'badges', 'languages', 'offers', 'plate', 'brandedQr', 'address']) {
      expect(t[id], isFalse, reason: id);
    }
    expect(t['priority_support'], isFalse);
  });

  test('Signature: customization yes, web address no; MasterChef: everything it is given', () {
    final s = _ticks(_plan(PlanId.signature, features: ['whatsapp_instagram_buttons']));
    expect(s['themes'], isTrue);
    expect(s['address'], isFalse);
    expect(s['whatsapp_instagram_buttons'], isTrue);
    expect(s['per_dish_analytics'], isFalse);

    final m = _ticks(_plan(PlanId.masterchef, features: [
      'whatsapp_instagram_buttons',
      'website_embed',
      'per_dish_analytics',
      'priority_support',
    ]));
    expect(m.values.every((v) => v), isTrue);
  });

  test('a zero cap is a cross, and an unknown server feature key is still shown', () {
    final benefits = planBenefits(_plan(PlanId.signature, standees: 0, features: ['new_thing']));
    expect(benefits.firstWhere((b) => b.id == 'standees').included, isFalse);
    expect(benefits.firstWhere((b) => b.id == 'new_thing').label, 'new thing');
  });

  testWidgets('the comparison fits a 360-wide phone, one row per benefit, ✗ where a plan lacks it',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanComparison(
          currentPlanId: PlanId.signature,
          plans: [
            _plan(PlanId.taste, threeD: 3),
            _plan(PlanId.signature, features: ['whatsapp_instagram_buttons']),
            _plan(PlanId.masterchef, threeD: 40, features: ['priority_support']),
          ],
        ),
      ),
    ));
    expect(tester.takeException(), isNull); // no RenderFlex overflow
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('40'), findsOneWidget); // a count, not a tick
    await tester.scrollUntilVisible(find.byKey(const ValueKey('plan_comparison_row_priority_support')), 200,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('plan_comparison_list')), matching: find.byType(Scrollable)));
    expect(tester.takeException(), isNull);
  });
}
