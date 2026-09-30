// lib/presentation/screens/catalog/customers_screen.dart
//
// `/catalog/customers` — the WhatsApp-offers list (more-customization Stage 12.2):
// the switch for the sign-up card on the menu, counts, this week's birthdays,
// search, a CSV of subscribed contacts, and per contact: open a WhatsApp chat with
// the owner's message, mark as opted out (they replied STOP), or delete.
//
// SENDING IS ONE CHAT AT A TIME, BY THE OWNER — there is no bulk send here (that
// needs the WhatsApp Business API; separate design). Owner only: reps never see
// diners' numbers.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../application/catalog/catalog_link_service.dart';
import '../../../application/catalog/catalog_qr_service.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/customers_repository.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

const double _kMaxWidth = 720;

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();
  final _message = TextEditingController(
    text: 'Hi {name}! 🎉 A special offer for you this week at our restaurant. Reply STOP to stop these messages.',
  );
  String _query = '';
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    _message.dispose();
    super.dispose();
  }

  String _messageFor(CustomerContact c) =>
      _message.text.replaceAll('{name}', (c.name ?? '').trim().isEmpty ? 'there' : c.name!.trim());

  Future<void> _run(Future<void> Function() action, String done) async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(customerListProvider);
      if (mounted && done.isNotEmpty) CatalogFeedback.confirm(messenger, done);
    } on CatalogFailure catch (failure) {
      if (mounted) CatalogFeedback.failure(messenger, failure, subject: 'customers');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run(() async {
        final bytes = await ref.read(customersRepositoryProvider).exportCsv();
        await ref.read(qrDelivererProvider).deliver(
              QrDownloadFile(bytes: bytes, fileName: 'customers.csv', mimeType: 'text/csv'),
            );
      }, '');

  Future<void> _toggleOptIn(bool on) => _run(() async {
        await ref.read(menuExtrasRepositoryProvider).updateOptIn(on);
        await ref.read(businessProfileProvider.notifier).refresh();
      }, 'Saved. It shows on your menu after you publish.');

  Future<void> _openChat(CustomerContact c) async {
    final digits = c.phone.replaceAll(RegExp(r'\D'), '');
    await ref
        .read(catalogLinkActionsProvider)
        .open('https://wa.me/$digits?text=${Uri.encodeComponent(_messageFor(c))}');
  }

  Future<void> _rowAction(CustomerContact c, String action) async {
    switch (action) {
      case 'chat':
        await _openChat(c);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: c.phone));
        if (mounted) CatalogFeedback.confirm(CatalogFeedback.of(context), 'Number copied.');
      case 'optout':
        await _run(() => ref.read(customersRepositoryProvider).markOptedOut(c.id),
            'Marked as opted out. They will not be in exports.');
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete this customer?'),
            content: const Text('Their number is removed from your list for good.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) await _run(() => ref.read(customersRepositoryProvider).delete(c.id), 'Deleted.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(customerListProvider(_query));
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Customers'),
        actions: [
          IconButton(
            key: const Key('customers-export'),
            tooltip: 'Export CSV',
            icon: const Icon(Icons.download_outlined),
            onPressed: _busy ? null : _export,
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.people_outline,
          title: 'Customers unavailable',
          body: error is CatalogFailure ? error.message : 'Something went wrong. Please try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(customerListProvider),
        ),
        data: (list) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              children: [
                AppCard(
                  child: SwitchListTile(
                    key: const Key('customers-optin-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('"Get offers on WhatsApp" on my menu'),
                    subtitle: const Text(
                      'Customers choose to join — the box is never pre-ticked, and they can '
                      'opt out any time. The menu never asks before showing dishes.',
                    ),
                    value: list.optInEnabled,
                    onChanged: _busy ? null : _toggleOptIn,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '${list.subscribed} subscribed · ${list.optedOut} opted out'
                  '${list.fresh ? '' : ' · could not refresh, showing the saved list'}',
                  style: muted,
                ),
                if (list.birthdaysThisWeek.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  AppCard(
                    key: const Key('customers-birthdays'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🎂 ${list.birthdaysThisWeek.length} customer'
                          '${list.birthdaysThisWeek.length == 1 ? ' has a birthday' : 's have birthdays'} this week',
                          style: text.titleSmall?.copyWith(color: AppColors.textPrimary),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        for (final c in list.birthdaysThisWeek)
                          Text('${c.name ?? c.phone} · ${c.birthdayLabel}', style: muted),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Message to send'),
                  subtitle: Text('Opens WhatsApp with this text, one customer at a time. {name} = their name.',
                      style: muted),
                  children: [
                    TextField(controller: _message, maxLines: 4, maxLength: 500),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy message'),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _message.text));
                          if (context.mounted) {
                            CatalogFeedback.confirm(CatalogFeedback.of(context), 'Message copied.');
                          }
                        },
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search by name or number',
                  ),
                  onSubmitted: (v) => setState(() => _query = v.trim()),
                ),
                const SizedBox(height: AppSpacing.md),
                if (list.customers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Text(
                      list.optInEnabled
                          ? 'No sign-ups yet. They appear here after customers join from your menu.'
                          : 'Switch the sign-up card on, publish, and customers can join from your menu.',
                      style: muted,
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  for (final c in list.customers)
                    ListTile(
                      key: Key('customer-${c.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.name ?? c.phone,
                          style: text.bodyLarge?.copyWith(
                              color: c.optedOut ? AppColors.textMuted : AppColors.textPrimary)),
                      subtitle: Text(
                        [
                          if (c.name != null) c.phone,
                          if (c.birthdayLabel != null) '🎂 ${c.birthdayLabel}',
                          if (c.optedOut) 'Opted out',
                        ].join(' · '),
                        style: muted,
                      ),
                      trailing: PopupMenuButton<String>(
                        enabled: !_busy,
                        onSelected: (a) => _rowAction(c, a),
                        itemBuilder: (_) => [
                          if (!c.optedOut) const PopupMenuItem(value: 'chat', child: Text('Open WhatsApp chat')),
                          const PopupMenuItem(value: 'copy', child: Text('Copy number')),
                          if (!c.optedOut)
                            const PopupMenuItem(value: 'optout', child: Text('Mark opted out (replied STOP)')),
                          const PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
