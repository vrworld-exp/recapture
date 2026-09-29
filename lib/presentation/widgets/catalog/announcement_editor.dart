// lib/presentation/widgets/catalog/announcement_editor.dart
//
// The announcement strip (more-customization Stage 4): a card showing the
// current one with its "Scheduled / Live / Expired" label, and a sheet to edit
// it — text, style, an optional date window and link, or Clear.
//
// It reaches the menu on Publish (D6), but the date window then runs on its own
// on the public page: an owner sets the Diwali offer once and it appears and
// disappears on its dates without another publish. The card says so.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/catalog_scope.dart';
import '../../../domain/catalog/menu_time.dart';
import '../app_button.dart';
import 'catalog_feedback.dart';

String _date(DateTime d) {
  final l = d.toLocal();
  return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
}

String announcementPhaseLabel(AnnouncementPhase p) => switch (p) {
      AnnouncementPhase.scheduled => 'Scheduled',
      AnnouncementPhase.live => 'Live',
      AnnouncementPhase.expired => 'Expired',
    };

/// The card: what is set now, and the way to change it.
class AnnouncementCard extends ConsumerWidget {
  const AnnouncementCard({super.key, required this.scope});

  final CatalogScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcement =
        ref.watch(businessProfileFor(scope).select((p) => p.valueOrNull?.announcement));
    final text = Theme.of(context).textTheme;
    final phase = announcement?.phaseAt(DateTime.now());

    return Container(
      key: const Key('announcement-card'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.textMuted.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.campaign_outlined, color: AppColors.royalGold),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Announcement', style: text.titleSmall),
                    if (phase != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _PhaseChip(phase: phase),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  announcement?.text ?? 'A one-line strip on your menu — an offer, a festival, a notice.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('announcement-edit'),
            onPressed: () => showAnnouncementEditor(context, scope),
            child: Text(announcement == null ? 'Add' : 'Edit'),
          ),
        ],
      ),
    );
  }
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.phase});

  final AnnouncementPhase phase;

  @override
  Widget build(BuildContext context) {
    final color = switch (phase) {
      AnnouncementPhase.live => AppColors.success,
      AnnouncementPhase.scheduled => AppColors.warning,
      AnnouncementPhase.expired => AppColors.textMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        announcementPhaseLabel(phase),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

Future<void> showAnnouncementEditor(BuildContext context, CatalogScope scope) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface1,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: AnnouncementEditor(scope: scope),
      ),
    );

class AnnouncementEditor extends ConsumerStatefulWidget {
  const AnnouncementEditor({super.key, required this.scope});

  final CatalogScope scope;

  @override
  ConsumerState<AnnouncementEditor> createState() => _AnnouncementEditorState();
}

class _AnnouncementEditorState extends ConsumerState<AnnouncementEditor> {
  late final CatalogAnnouncement? _initial =
      ref.read(businessProfileFor(widget.scope)).valueOrNull?.announcement;
  late final TextEditingController _text = TextEditingController(text: _initial?.text ?? '');
  late final TextEditingController _link = TextEditingController(text: _initial?.link ?? '');
  late AnnouncementStyle _style = _initial?.style ?? AnnouncementStyle.info;
  late DateTime? _startsAt = _initial?.startsAt;
  late DateTime? _endsAt = _initial?.endsAt;
  bool _saving = false;
  CatalogFailure? _error;

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  CatalogAnnouncement get _draft => CatalogAnnouncement(
        text: _text.text,
        style: _style,
        startsAt: _startsAt,
        endsAt: _endsAt,
        link: _link.text.trim().isEmpty ? null : _link.text.trim(),
      );

  Future<DateTime?> _pickDate(DateTime? current, {required bool endOfDay}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: now.add(const Duration(days: 366)),
      initialDate: current?.toLocal() ?? now,
    );
    if (picked == null) return null;
    // A start date means from that morning; an end date means through that night.
    return endOfDay
        ? DateTime(picked.year, picked.month, picked.day).add(const Duration(days: 1))
        : DateTime(picked.year, picked.month, picked.day);
  }

  Future<void> _save(CatalogAnnouncement? value) async {
    final messenger = CatalogFeedback.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(businessProfileFor(widget.scope).notifier).saveAnnouncement(value);
      if (!mounted) return;
      navigator.pop();
      CatalogFeedback.confirm(
        messenger,
        value == null
            ? 'Announcement cleared. It leaves your menu the next time you publish.'
            : 'Announcement saved. It reaches your menu the next time you publish.',
      );
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
    final problem = _draft.validate();
    final text = Theme.of(context).textTheme;
    final endShown = _endsAt?.subtract(const Duration(days: 1));

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Announcement', style: text.titleLarge),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('announcement-text'),
              controller: _text,
              maxLength: kMaxAnnouncementLength,
              enabled: !_saving,
              decoration: const InputDecoration(
                hintText: 'Diwali special — 20% off all thalis',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final s in AnnouncementStyle.values)
                  ChoiceChip(
                    key: Key('announcement-style-${s.apiValue}'),
                    label: Text(s.label),
                    selected: _style == s,
                    onSelected: _saving ? null : (_) => setState(() => _style = s),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('announcement-start'),
                    onPressed: _saving
                        ? null
                        : () async {
                            final d = await _pickDate(_startsAt, endOfDay: false);
                            if (d != null) setState(() => _startsAt = d);
                          },
                    child: Text(_startsAt == null ? 'Starts: now' : 'From ${_date(_startsAt!)}'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    key: const Key('announcement-end'),
                    onPressed: _saving
                        ? null
                        : () async {
                            final d = await _pickDate(endShown, endOfDay: true);
                            if (d != null) setState(() => _endsAt = d);
                          },
                    child: Text(endShown == null ? 'Ends: never' : 'Until ${_date(endShown)}'),
                  ),
                ),
              ],
            ),
            if (_startsAt != null || _endsAt != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _startsAt = null;
                            _endsAt = null;
                          }),
                  child: const Text('No dates'),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('announcement-link'),
              controller: _link,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'Link (optional) — https://…'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Goes on your menu when you publish. After that the dates run on their '
              'own — no need to publish again when it starts or ends.',
              style: text.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            if ((_text.text.isNotEmpty && problem != null) || _error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _error != null ? CatalogFeedback.failureText(_error!) : problem!,
                style: text.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              key: const Key('announcement-save'),
              label: 'Save announcement',
              isLoading: _saving,
              onPressed: problem == null && !_saving ? () => _save(_draft) : null,
            ),
            if (_initial != null) ...[
              const SizedBox(height: AppSpacing.sm),
              AppButton.secondary(
                key: const Key('announcement-clear'),
                label: 'Clear announcement',
                onPressed: _saving ? null : () => _save(null),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
