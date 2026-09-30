// lib/presentation/screens/catalog/plate_settings_screen.dart
//
// `/catalog/plate` — the "My plate" switches (more-customization Stage 11).
//
// ITS OWN SCREEN, NOT A SECTION OF "Spotlight & customer buttons": that screen's
// entry is hidden behind the `appearanceEnabled` rollout flag (Stage 8), and My
// plate is ON by default — the owner must always be able to reach the off switch.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';

class PlateSettingsScreen extends ConsumerWidget {
  const PlateSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(businessProfileProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('My plate')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.restaurant_menu,
          title: 'Could not load your settings',
          body: error is CatalogFailure ? error.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.read(businessProfileProvider.notifier).refresh(),
        ),
        data: (value) => value == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first.',
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    children: [PlateSettingsSection(saved: value.plate)],
                  ),
                ),
              ),
      ),
    );
  }
}

// ── My plate (Stage 11) ─────────────────────────────────────────────────────

class PlateSettingsSection extends ConsumerStatefulWidget {
  const PlateSettingsSection({super.key, required this.saved});

  final MenuPlate saved;

  @override
  ConsumerState<PlateSettingsSection> createState() => _PlateSectionState();
}

class _PlateSectionState extends ConsumerState<PlateSettingsSection> {
  late MenuPlate _value = widget.saved;
  bool _saving = false;

  Future<void> _save(MenuPlate next) async {
    final previous = _value;
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _value = next;
      _saving = true;
    });
    try {
      await ref.read(menuExtrasRepositoryProvider).updatePlate(next);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      CatalogFeedback.confirm(messenger, 'Saved. It shows after your next publish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() => _value = previous);
      CatalogFeedback.failure(messenger, failure, subject: 'My plate');
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
            Text('My plate', style: text.titleLarge),
            const SizedBox(width: AppSpacing.sm),
            // Signature and above; on a lower plan the menu shows no + buttons.
            EntitlementLock(feature: 'plate', covered: (e) => e.plate),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Customers tap + on dishes and show one clear list to the waiter — in your '
          'menu\'s own language. It is not an order: nothing is sent to you or paid.',
          style: muted,
        ),
        SwitchListTile(
          key: const Key('plate-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Let customers build a plate'),
          value: _value.enabled,
          onChanged: _saving ? null : (v) => _save(_value.copyWith(enabled: v)),
        ),
        SwitchListTile(
          key: const Key('plate-show-total'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show the running total'),
          subtitle: const Text('Some fine-dining restaurants prefer not to.'),
          value: _value.showTotal,
          onChanged: _saving || !_value.enabled
              ? null
              : (v) => _save(_value.copyWith(showTotal: v)),
        ),
      ],
    );
  }
}
