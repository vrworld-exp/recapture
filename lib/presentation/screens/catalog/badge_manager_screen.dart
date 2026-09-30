// lib/presentation/screens/catalog/badge_manager_screen.dart
//
// The badge library (more-customization Stage 5): the owner designs a badge
// once — "Chef's special", chef's-hat icon, gold — and puts it on any dish from
// the product editor.
//
// First open with no badges offers the six suggestions, which are NOT saved
// until the owner saves. Deleting a badge removes it from every dish carrying
// it (the server does that in the same request) — the confirmation says so.
// Everything reaches the menu at the next Publish.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/business_profile_repository.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/dish_details.dart';
import '../../../domain/catalog/menu_entitlements.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/plan_lock_chip.dart';
import '../../widgets/catalog/dish_badge_chip.dart';

class BadgeManagerScreen extends ConsumerWidget {
  const BadgeManagerScreen({super.key});

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
        title: Text('Badges', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your badges",
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
            : _BadgeEditor(key: ValueKey(profile.id), saved: profile.badges),
      ),
    );
  }
}

class _BadgeEditor extends ConsumerStatefulWidget {
  const _BadgeEditor({super.key, required this.saved});

  final List<CatalogBadge> saved;

  @override
  ConsumerState<_BadgeEditor> createState() => _BadgeEditorState();
}

class _BadgeEditorState extends ConsumerState<_BadgeEditor> {
  // First visit: the suggestions, unsaved. Otherwise what is stored.
  late List<CatalogBadge> _badges =
      widget.saved.isEmpty ? [...CatalogBadge.suggestions] : [...widget.saved];
  late List<CatalogBadge> _baseline = [...widget.saved];
  bool _saving = false;
  CatalogFailure? _error;

  bool get _dirty =>
      _badges.length != _baseline.length ||
      [
        for (var i = 0; i < _badges.length; i++)
          _badges[i].toMap().toString() != _baseline[i].toMap().toString(),
      ].any((changed) => changed);

  String? get _problem {
    if (_badges.length > kMaxBadges) return 'At most $kMaxBadges badges.';
    for (final b in _badges) {
      final p = b.validate();
      if (p != null) return p;
    }
    return null;
  }

  Future<void> _edit(int? index) async {
    final result = await showDialog<CatalogBadge>(
      context: context,
      builder: (_) => _BadgeDialog(
        initial: index == null
            ? const CatalogBadge(label: '', icon: BadgeIcon.star, color: BadgeColor.accent)
            : _badges[index],
      ),
    );
    if (result == null) return;
    setState(() => index == null ? _badges.add(result) : _badges[index] = result);
  }

  Future<void> _remove(int index) async {
    final badge = _badges[index];
    // Only a SAVED badge is on dishes; an unsaved suggestion just goes.
    if (badge.id != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text('Delete "${badge.label}"?'),
          content: const Text(
            'It comes off every dish that has it when you save. Customers stop '
            'seeing it after your next publish.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.error)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _badges.removeAt(index));
  }

  Future<void> _save() async {
    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = await ref.read(businessProfileRepositoryProvider).updateBadges(_badges);
      await ref.read(businessProfileProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _badges = [...profile.badges];
        _baseline = [...profile.badges];
      });
      CatalogFeedback.confirm(messenger, 'Badges saved. Add them to dishes from each dish.');
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final problem = _problem;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.saved.isEmpty
                    ? 'Here are some to start with — edit, delete or add your own, then save.'
                    : 'Design a badge once, then put it on any dish. A dish card shows two.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              EntitlementLimitNote(
                text: (e) => e.entitlements.maxBadges >= kMaxBadges
                    ? null
                    : 'Your plan shows your first ${e.entitlements.maxBadges} badges on the menu; '
                        'all $kMaxBadges need ${planLabel(e.requiredPlan['badges'])}.',
              ),
              const SizedBox(height: AppSpacing.lg),
              for (var i = 0; i < _badges.length; i++)
                ListTile(
                  key: Key('badge-row-$i'),
                  contentPadding: EdgeInsets.zero,
                  title: Align(
                    alignment: Alignment.centerLeft,
                    child: DishBadgeChip(badge: _badges[i]),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: _saving ? null : () => _edit(i),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: _saving ? null : () => _remove(i),
                      ),
                    ],
                  ),
                ),
              if (_badges.length < kMaxBadges)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('badge-add'),
                    onPressed: _saving ? null : () => _edit(null),
                    icon: const Icon(Icons.add),
                    label: const Text('Add a badge'),
                  ),
                ),
              if (problem != null || _error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  problem ?? CatalogFeedback.failureText(_error!),
                  style: text.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const Key('badge-save'),
                label: 'Save badges',
                isLoading: _saving,
                onPressed: (_dirty || widget.saved.isEmpty && _badges.isNotEmpty) &&
                        problem == null &&
                        !_saving
                    ? _save
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BadgeDialog extends StatefulWidget {
  const _BadgeDialog({required this.initial});

  final CatalogBadge initial;

  @override
  State<_BadgeDialog> createState() => _BadgeDialogState();
}

class _BadgeDialogState extends State<_BadgeDialog> {
  late final TextEditingController _label = TextEditingController(text: widget.initial.label);
  late BadgeIcon _icon = widget.initial.icon;
  late BadgeColor _color = widget.initial.color;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  CatalogBadge get _badge => widget.initial.copyWith(label: _label.text, icon: _icon, color: _color);

  @override
  Widget build(BuildContext context) {
    final problem = _label.text.isEmpty ? null : _badge.validate();
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Badge'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(alignment: Alignment.centerLeft, child: DishBadgeChip(badge: _badge)),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('badge-label'),
              controller: _label,
              maxLength: kMaxBadgeLabel,
              decoration: const InputDecoration(hintText: "Chef's special"),
              onChanged: (_) => setState(() {}),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final icon in BadgeIcon.values)
                  ChoiceChip(
                    label: Icon(badgeIconData(icon), size: 16),
                    selected: _icon == icon,
                    onSelected: (_) => setState(() => _icon = icon),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final color in BadgeColor.values)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: badgeColor(color), radius: 6),
                    label: Text(color.label),
                    selected: _color == color,
                    onSelected: (_) => setState(() => _color = color),
                  ),
              ],
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  problem,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          key: const Key('badge-dialog-done'),
          onPressed: _badge.validate() == null ? () => Navigator.pop(context, _badge) : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
