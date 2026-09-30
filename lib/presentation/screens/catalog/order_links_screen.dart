// lib/presentation/screens/catalog/order_links_screen.dart
//
// `/catalog/links` — "Order online" and "Book a table" on the menu
// (more-customization Stage 12.3). Only the platforms filled in show; each link
// must be on that platform's own site (the server re-checks).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../widgets/app_button.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

class OrderLinksScreen extends ConsumerWidget {
  const OrderLinksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(businessProfileProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
          backgroundColor: Colors.transparent, elevation: 0, title: const Text('Order & booking links')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.delivery_dining_outlined,
          title: 'Could not load your links',
          body: error is CatalogFailure ? error.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.read(businessProfileProvider.notifier).refresh(),
        ),
        data: (value) => value == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined, title: 'No catalog yet', body: 'Create your catalog first.')
            : _LinksForm(saved: value.links),
      ),
    );
  }
}

class _LinksForm extends ConsumerStatefulWidget {
  const _LinksForm({required this.saved});
  final MenuLinks saved;

  @override
  ConsumerState<_LinksForm> createState() => _LinksFormState();
}

class _LinksFormState extends ConsumerState<_LinksForm> {
  late final Map<DeliveryPlatform, TextEditingController> _urls = {
    for (final p in DeliveryPlatform.values) p: TextEditingController(text: widget.saved.delivery[p] ?? ''),
  };
  late BookingType? _bookingType = widget.saved.bookingType;
  late final TextEditingController _booking = TextEditingController(text: widget.saved.bookingValue ?? '');
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _urls.values) {
      c.dispose();
    }
    _booking.dispose();
    super.dispose();
  }

  String? _urlError(DeliveryPlatform p) {
    final v = _urls[p]!.text.trim();
    if (v.isEmpty || p.accepts(v)) return null;
    return 'Paste your ${p.label} page link (https://…${p.hosts.first}/…)';
  }

  String? get _bookingError {
    final v = _booking.text.trim();
    if (_bookingType == null || v.isEmpty) return null;
    if (_bookingType == BookingType.url) return v.startsWith('https://') ? null : 'Must start with https://';
    return v.replaceAll(RegExp(r'\D'), '').length >= 10 ? null : 'Enter a 10-digit number';
  }

  bool get _valid =>
      DeliveryPlatform.values.every((p) => _urlError(p) == null) && _bookingError == null;

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _saving = true);
    try {
      final links = MenuLinks(
        delivery: {
          for (final p in DeliveryPlatform.values)
            if (_urls[p]!.text.trim().isNotEmpty) p: _urls[p]!.text.trim(),
        },
        bookingType: _booking.text.trim().isEmpty ? null : _bookingType,
        bookingValue: _booking.text.trim().isEmpty ? null : _booking.text.trim(),
      );
      await ref.read(menuExtrasRepositoryProvider).updateLinks(links);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (mounted) CatalogFeedback.confirm(messenger, 'Saved. The links show after your next publish.');
    } on CatalogFailure catch (failure) {
      if (mounted) CatalogFeedback.failure(messenger, failure, subject: 'links');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          children: [
            Text('Order online', style: text.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text('Customers see a button for each one you fill in, in your menu\'s contact sheet.', style: muted),
            for (final p in DeliveryPlatform.values)
              TextField(
                key: Key('links-${p.key}'),
                controller: _urls[p],
                enabled: !_saving,
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: '${p.label} link (optional)', errorText: _urlError(p)),
              ),
            const SizedBox(height: AppSpacing.xxl),
            Text('Book a table', style: text.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<BookingType?>(
              segments: [
                const ButtonSegment(value: null, label: Text('Off')),
                for (final t in BookingType.values) ButtonSegment(value: t, label: Text(t.label)),
              ],
              selected: {_bookingType},
              onSelectionChanged: _saving ? null : (s) => setState(() => _bookingType = s.first),
            ),
            if (_bookingType != null)
              TextField(
                controller: _booking,
                enabled: !_saving,
                keyboardType: _bookingType == BookingType.url ? TextInputType.url : TextInputType.phone,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _bookingType == BookingType.url ? 'Booking page (https://…)' : 'Phone / WhatsApp number',
                  helperText: _bookingType == BookingType.whatsapp
                      ? 'Opens WhatsApp with "Hi, I\'d like to book a table for __ people on __ at __".'
                      : null,
                  errorText: _bookingError,
                ),
              ),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              key: const Key('links-save'),
              label: 'Save links',
              isLoading: _saving,
              onPressed: _saving || !_valid ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
