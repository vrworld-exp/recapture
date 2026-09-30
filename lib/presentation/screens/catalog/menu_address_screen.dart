// lib/presentation/screens/catalog/menu_address_screen.dart
//
// "Menu web address" (more-customization Stage 8.2, phase 1): a pretty address
// for the menu — `cafe-blue.<our menu domain>` — on our own wildcard domain.
//
// Said plainly on the screen: this is an EXTRA address. The link inside the
// printed QR never changes, so every QR already on a table keeps working; the
// owner may print new ones with the pretty address if they like.
//
// Saved on any plan, shown on the menu only on a plan that covers it (the
// publish holds it back otherwise, like every Stage 8 gate).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';

/// Mirrors catalogSlugService SLUG_RE — 3–40, lowercase, digits, single hyphens.
final RegExp _slugRe = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$');

class MenuAddressScreen extends ConsumerWidget {
  const MenuAddressScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(businessProfileProvider);
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
        title: Text('Menu web address', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your address",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(businessProfileProvider),
        ),
        data: (profile) => profile == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first.',
              )
            : _AddressForm(key: ValueKey(profile.id), slug: profile.slug, url: profile.slugUrl),
      ),
    );
  }
}

class _AddressForm extends ConsumerStatefulWidget {
  const _AddressForm({super.key, required this.slug, required this.url});

  final String? slug;
  final String? url;

  @override
  ConsumerState<_AddressForm> createState() => _AddressFormState();
}

class _AddressFormState extends ConsumerState<_AddressForm> {
  late final TextEditingController _slug = TextEditingController(text: widget.slug ?? '');
  late String? _saved = widget.slug;
  late String? _url = widget.url;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  String get _value => _slug.text.trim().toLowerCase();

  String? get _problem {
    final v = _value;
    if (v.isEmpty) return null;
    if (!_slugRe.hasMatch(v) || v.contains('--')) {
      return 'Use 3–40 lowercase letters, numbers and single hyphens.';
    }
    return null;
  }

  Future<void> _save({bool clear = false}) async {
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final (slug, url) = await ref
          .read(menuExtrasRepositoryProvider)
          .setSlug(clear || _value.isEmpty ? null : _value);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = slug;
        _url = url;
        if (slug == null) _slug.clear();
      });
      CatalogFeedback.confirm(
        messenger,
        slug == null ? 'Address removed.' : 'Saved. It works after your next publish.',
      );
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = CatalogFeedback.failureText(failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final problem = _problem;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: EntitlementLock(feature: 'customDomain', covered: (e) => e.customDomain),
              ),
              Text(
                'An easy web address for your menu — handy for Instagram, WhatsApp and '
                'visiting cards. It is an extra address: the link inside your printed QR '
                'never changes, so the QR codes on your tables keep working.',
                style: muted,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                key: const Key('menu-address-slug'),
                controller: _slug,
                enabled: !_saving,
                maxLength: 40,
                autocorrect: false,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9-]')),
                ],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Your address',
                  hintText: 'blue-cafe',
                  errorText: problem,
                ),
              ),
              if (_url != null && _saved != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(child: SelectableText(_url!, key: const Key('menu-address-url'))),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => Clipboard.setData(ClipboardData(text: _url!)),
                    ),
                  ],
                ),
              ] else if (_saved != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Saved as "$_saved". The address goes live when menu addresses are switched on.',
                    style: muted),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: text.bodySmall?.copyWith(color: AppColors.warning)),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const Key('menu-address-save'),
                label: 'Save address',
                isLoading: _saving,
                onPressed: !_saving && problem == null && _value.isNotEmpty && _value != _saved
                    ? () => _save()
                    : null,
              ),
              if (_saved != null)
                TextButton(
                  key: const Key('menu-address-remove'),
                  onPressed: _saving ? null : () => _save(clear: true),
                  child: const Text('Remove address'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
