// lib/presentation/screens/catalog/menu_extras_screen.dart
//
// "Spotlight & customer buttons" (more-customization Stage 7.2 / 7.3):
//   • Spotlight — up to six hand-picked dishes in a carousel at the top of the
//     menu (3D dishes get a "View in AR" button there);
//   • Customer buttons — Rate us (a Google review link), Order on WhatsApp,
//     Call waiter, the Wi-Fi details, and a feedback form whose replies show on
//     the analytics screen.
//
// The two sections save separately. Everything reaches the menu at Publish.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../application/catalog/menu_translations_provider.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../data/repositories/menu_translations_repository.dart';
import '../../../domain/catalog/menu_entitlements.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';

class MenuExtrasScreen extends ConsumerWidget {
  const MenuExtrasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(menuTranslationsProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Text('Spotlight & buttons', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: dataAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your menu",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(menuTranslationsProvider),
        ),
        data: (data) => data == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first.',
              )
            : _ExtrasBody(key: ValueKey(data.profile.id), data: data),
      ),
    );
  }
}

class _ExtrasBody extends StatelessWidget {
  const _ExtrasBody({super.key, required this.data});

  final MenuTranslationsData data;

  @override
  Widget build(BuildContext context) {
    final products = [for (final p in data.products) if (!p.isArchived) p];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SpotlightSection(saved: data.profile.spotlight, products: products),
              const Divider(height: AppSpacing.xxxl * 2),
              _EngagementSection(
                saved: data.profile.engagement,
                hasWhatsapp: (data.profile.contact?.socials?.whatsapp ?? '').trim().isNotEmpty,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Spotlight ───────────────────────────────────────────────────────────────

class _SpotlightSection extends ConsumerStatefulWidget {
  const _SpotlightSection({required this.saved, required this.products});

  final MenuSpotlight saved;
  final List<CatalogProduct> products;

  @override
  ConsumerState<_SpotlightSection> createState() => _SpotlightSectionState();
}

class _SpotlightSectionState extends ConsumerState<_SpotlightSection> {
  late bool _enabled = widget.saved.enabled;
  late List<String> _ids = [
    for (final id in widget.saved.productIds)
      if (widget.products.any((p) => p.id == id)) id,
  ];
  late final TextEditingController _title = TextEditingController(text: widget.saved.title ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _toggle(String id) => setState(() {
        if (_ids.contains(id)) {
          _ids.remove(id);
        } else if (_ids.length < kMaxSpotlightDishes) {
          _ids = [..._ids, id];
        }
      });

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(menuExtrasRepositoryProvider).updateSpotlight(
            MenuSpotlight(enabled: _enabled, productIds: _ids, title: _title.text.trim()),
          );
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      CatalogFeedback.confirm(messenger, 'Spotlight saved. It shows after your next publish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      CatalogFeedback.failure(messenger, failure, subject: 'spotlight');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Spotlight', style: text.titleLarge),
            const SizedBox(width: AppSpacing.sm),
            EntitlementLock(feature: 'spotlight', covered: (e) => e.arBrandingAndSpotlight),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Up to $kMaxSpotlightDishes dishes in a carousel at the top of your menu. '
          'Dishes with 3D get a "View in AR" button there.',
          style: muted,
        ),
        SwitchListTile(
          key: const Key('spotlight-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show the spotlight'),
          value: _enabled,
          onChanged: _saving ? null : (v) => setState(() => _enabled = v),
        ),
        TextField(
          key: const Key('spotlight-title'),
          controller: _title,
          maxLength: kMaxSpotlightTitle,
          enabled: !_saving,
          decoration: const InputDecoration(labelText: 'Title (optional)', hintText: 'Chef recommends'),
        ),
        Text('${_ids.length} of $kMaxSpotlightDishes picked', style: muted),
        const SizedBox(height: AppSpacing.sm),
        if (widget.products.isEmpty) Text('No dishes yet.', style: muted),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final p in widget.products)
              FilterChip(
                key: Key('spotlight-dish-${p.id}'),
                label: Text(
                  _ids.contains(p.id) ? '${_ids.indexOf(p.id) + 1}. ${p.displayName}' : p.displayName,
                ),
                avatar: p.isArReady ? const Icon(Icons.view_in_ar, size: 16) : null,
                selected: _ids.contains(p.id),
                onSelected: _saving ||
                        (!_ids.contains(p.id) && _ids.length >= kMaxSpotlightDishes)
                    ? null
                    : (_) => _toggle(p.id),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          key: const Key('spotlight-save'),
          label: 'Save spotlight',
          isLoading: _saving,
          onPressed: _saving || (_enabled && _ids.isEmpty) ? null : _save,
        ),
      ],
    );
  }
}

// ── Customer buttons ────────────────────────────────────────────────────────

class _EngagementSection extends ConsumerStatefulWidget {
  const _EngagementSection({required this.saved, required this.hasWhatsapp});

  final MenuEngagement saved;
  final bool hasWhatsapp;

  @override
  ConsumerState<_EngagementSection> createState() => _EngagementSectionState();
}

class _EngagementSectionState extends ConsumerState<_EngagementSection> {
  late final TextEditingController _review =
      TextEditingController(text: widget.saved.reviewUrl ?? '');
  late final TextEditingController _ssid = TextEditingController(text: widget.saved.wifiSsid ?? '');
  late final TextEditingController _password =
      TextEditingController(text: widget.saved.wifiPassword ?? '');
  late bool _whatsappOrder = widget.saved.whatsappOrder;
  late bool _callWaiter = widget.saved.callWaiter;
  late bool _feedback = widget.saved.feedbackForm;
  bool _saving = false;

  @override
  void dispose() {
    _review.dispose();
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  MenuEngagement get _value => MenuEngagement(
        // A pasted Place ID is turned into Google's direct review link.
        reviewUrl: googleReviewLinkFrom(_review.text) ?? _review.text.trim(),
        whatsappOrder: _whatsappOrder,
        callWaiter: _callWaiter,
        wifiSsid: _ssid.text.trim(),
        wifiPassword: _password.text,
        feedbackForm: _feedback,
      );

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(menuExtrasRepositoryProvider).updateEngagement(_value);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      CatalogFeedback.confirm(messenger, 'Buttons saved. They show after your next publish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      CatalogFeedback.failure(messenger, failure, subject: 'buttons');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final problem = _value.validate();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Customer buttons', style: text.titleLarge),
            const SizedBox(width: AppSpacing.sm),
            EntitlementLock(feature: 'engagement', covered: (e) => e.allEngagement),
          ],
        ),
        EntitlementLimitNote(
          text: (e) => e.entitlements.allEngagement
              ? null
              : 'Your plan shows the review link only. The other buttons need ${planLabel(e.requiredPlan['engagement'])}.',
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('engagement-review'),
          controller: _review,
          enabled: !_saving,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Google review link (optional)',
            hintText: 'https://g.page/r/…/review — or paste your Place ID',
            helperText: 'Adds "Rate us". Customers are asked once a month, after 15 minutes '
                'on the menu or 20 minutes after showing their plate to the waiter.',
            helperMaxLines: 3,
            errorText: _review.text.trim().isEmpty || googleReviewLinkFrom(_review.text) != null
                ? null
                : 'Use your Google review link or Place ID (starts with ChIJ).',
          ),
        ),
        // Stage 12.1: a Place ID becomes the direct "write a review" link.
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('engagement-review-help'),
            icon: const Icon(Icons.help_outline, size: 16),
            label: const Text('Find my Google Place ID'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Your Google review link'),
                content: const SelectableText(
                  'Best: in Google Business Profile, tap "Ask for reviews" and paste that link here.\n\n'
                  'Or find your Place ID (it starts with ChIJ) with Google\'s Place ID finder:\n'
                  '$kPlaceIdFinderUrl\n\n'
                  'Paste the ID here and we build the link that opens the review box directly.',
                ),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (!widget.hasWhatsapp)
          Text(
            'Add your WhatsApp number on the business profile to use the WhatsApp buttons.',
            style: text.bodySmall?.copyWith(color: AppColors.warning),
          ),
        SwitchListTile(
          key: const Key('engagement-whatsapp-order'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Order on WhatsApp'),
          subtitle: Text('On every dish, with the dish and price filled in.', style: muted),
          value: _whatsappOrder,
          onChanged: _saving || !widget.hasWhatsapp ? null : (v) => setState(() => _whatsappOrder = v),
        ),
        SwitchListTile(
          key: const Key('engagement-call-waiter'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Call waiter'),
          subtitle: Text(
            'Sends you "Table 5 needs assistance" on WhatsApp. Table QRs ending in ?t=5 fill the table in.',
            style: muted,
          ),
          value: _callWaiter,
          onChanged: _saving || !widget.hasWhatsapp ? null : (v) => setState(() => _callWaiter = v),
        ),
        SwitchListTile(
          key: const Key('engagement-feedback'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Feedback form'),
          subtitle: Text('A 1–5 rating and a comment. Replies appear in Analytics.', style: muted),
          value: _feedback,
          onChanged: _saving ? null : (v) => setState(() => _feedback = v),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Wi-Fi (optional)', style: text.titleMedium),
        TextField(
          key: const Key('engagement-wifi-ssid'),
          controller: _ssid,
          enabled: !_saving,
          maxLength: 32,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Network name'),
        ),
        TextField(
          key: const Key('engagement-wifi-password'),
          controller: _password,
          enabled: !_saving,
          maxLength: 63,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Password',
            helperText: 'Anyone who opens your menu can see this.',
          ),
        ),
        if (problem != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(problem, style: text.bodySmall?.copyWith(color: AppColors.warning)),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          key: const Key('engagement-save'),
          label: 'Save buttons',
          isLoading: _saving,
          onPressed: _saving || problem != null ? null : _save,
        ),
      ],
    );
  }
}
