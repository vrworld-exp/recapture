// lib/presentation/screens/catalog/staff_screen.dart
//
// Staff access (more-customization Stage 14.3):
//   • [StaffScreen] — `/catalog/staff`, the OWNER invites people by phone as a
//     Manager (stock + prices + publish) or Staff (stock + publish), and
//     removes them. Removal works on their very next request.
//   • [MyStaffCatalogsScreen] — `/staff`, the restaurants the signed-in person
//     helps run; each opens its Today screen.
// Appearance, subscription, billing and customers stay with the owner.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_qr_service.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/today_repository.dart';
import '../../../domain/catalog/today.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import 'today_screen.dart';

class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  bool _manager = false;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(staffRepositoryProvider).invite(phone: _phone.text, manager: _manager, name: _name.text);
      _phone.clear();
      _name.clear();
      ref.invalidate(staffListProvider);
      if (mounted) {
        CatalogFeedback.confirm(messenger, 'Added. They sign in to ReCapture with this number to start.');
      }
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'invite');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(StaffMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${m.name ?? m.phone ?? 'this person'}?'),
        content: const Text('They lose access straight away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = CatalogFeedback.of(context);
    try {
      await ref.read(staffRepositoryProvider).revoke(m.id);
      ref.invalidate(staffListProvider);
    } on CatalogFailure catch (f) {
      if (mounted) CatalogFeedback.failure(messenger, f, subject: 'staff');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(staffListProvider);
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('Staff')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              Text(
                'Let your team update the menu without your account. Staff can mark dishes sold '
                'out and publish; a Manager can also change prices. Neither can see billing, your '
                'customers or the menu\'s look.',
                style: muted,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('staff-phone'),
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Their mobile number'),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _name,
                      maxLength: 40,
                      decoration: const InputDecoration(labelText: 'Name (optional)'),
                    ),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Staff')),
                        ButtonSegment(value: true, label: Text('Manager')),
                      ],
                      selected: {_manager},
                      onSelectionChanged: (s) => setState(() => _manager = s.first),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      key: const Key('staff-invite'),
                      label: 'Add',
                      isLoading: _busy,
                      onPressed: _busy || _phone.text.trim().length < 10 ? null : _invite,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text(e is CatalogFailure ? e.message : 'Could not load your team.', style: muted),
                data: (staff) => Column(
                  children: [
                    if (staff.isEmpty) Text('Nobody added yet. Up to 5 people.', style: muted),
                    for (final m in staff)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(m.manager ? Icons.manage_accounts_outlined : Icons.person_outline),
                        title: Text(m.name ?? m.phone ?? 'Team member'),
                        subtitle: Text(
                          '${m.manager ? 'Manager' : 'Staff'}'
                          '${m.name != null && m.phone != null ? ' · ${m.phone}' : ''}'
                          '${m.invited ? ' · waiting to sign in' : ''}',
                          style: muted,
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () => _remove(m),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MyStaffCatalogsScreen extends ConsumerWidget {
  const MyStaffCatalogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myStaffCatalogsProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('Restaurants I help run')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const SizedBox.shrink(),
        data: (catalogs) => catalogs.isEmpty
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No restaurants yet',
                body: 'When a restaurant owner adds your mobile number, it appears here.',
              )
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                children: [
                  for (final c in catalogs)
                    AppCard(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => TodayScreen(
                          staffCatalogId: c.catalogId,
                          permissions: c.permissions,
                          title: c.name,
                        ),
                      )),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(c.name),
                        subtitle: Text(c.manager ? 'Manager' : 'Staff'),
                        trailing: const Icon(Icons.chevron_right),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// "Printable menu" — template, size, QR, published vs draft → a PDF to share / print.
Future<void> showPrintableMenuDialog(BuildContext context, WidgetRef ref) async {
  var template = 'classic';
  var size = 'A4';
  var qr = true;
  var published = true;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Printable menu'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              children: [
                for (final (v, l) in const [('classic', 'Classic'), ('compact', 'Compact'), ('twoColumn', 'Two columns')])
                  ChoiceChip(label: Text(l), selected: template == v, onSelected: (_) => set(() => template = v)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final v in const ['A4', 'A5'])
                  ChoiceChip(label: Text(v), selected: size == v, onSelected: (_) => set(() => size = v)),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('QR to the live menu'),
              value: qr,
              onChanged: (v) => set(() => qr = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Only what is live'),
              subtitle: const Text('Off = include changes not yet published'),
              value: published,
              onChanged: (v) => set(() => published = v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Download')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  final messenger = CatalogFeedback.of(context);
  try {
    final bytes = await ref
        .read(staffRepositoryProvider)
        .menuPdf(template: template, size: size, includeQr: qr, published: published);
    await ref
        .read(qrDelivererProvider)
        .deliver(QrDownloadFile(bytes: bytes, fileName: 'menu-$size.pdf', mimeType: 'application/pdf'));
  } on CatalogFailure catch (f) {
    CatalogFeedback.failure(messenger, f, subject: 'menu PDF');
  }
}

/// Route helper for the owner's "Today" entry.
void openToday(BuildContext context) => context.push(AppRoutes.catalogToday);
