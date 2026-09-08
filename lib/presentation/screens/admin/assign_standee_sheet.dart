// lib/presentation/screens/admin/assign_standee_sheet.dart
//
// "Hand this standee to…" — the roster an admin picks from, and the one control
// that takes a standee back.
//
// IT RETURNS A DECISION, NOT A RESULT. The sheet closes with an
// [AssignStandeeChoice] and the CALLER performs the assignment, so the spinner
// and the failure both land on the row the admin is looking at rather than
// inside a sheet that is already gone. That is the same split
// `country_code_picker.dart` uses, and it is what lets one busy-row rule cover
// downloading and assigning alike.
//
// The list is fetched fresh each time this opens (see salesRepsProvider) —
// staff roles are granted by a script outside the app, so a session-cached
// roster would go stale with no way for anyone to notice.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/sales_reps_notifier.dart';
import '../../../domain/entities/qr_standee.dart';
import '../../../domain/entities/user_role.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

/// What the admin decided in the sheet.
sealed class AssignStandeeChoice {
  const AssignStandeeChoice();
}

/// Give the standee to this person.
class AssignToRep extends AssignStandeeChoice {
  const AssignToRep(this.rep);
  final SalesRepSummary rep;
}

/// Take it back off whoever holds it.
class UnassignStandee extends AssignStandeeChoice {
  const UnassignStandee();
}

/// Opens the picker for [subject]. Resolves to null if the admin backed out.
///
/// ONE PICKER, TWO SUBJECTS. This opens for a single standee and for a whole
/// batch, and the only differences are the words at the top and whether the
/// subject is set in monospace. A second sheet for the batch case would be a
/// second roster, a second empty state and a second failure path to keep in
/// step — the roster is the hard part, and it is identical either way.
///
/// [currentHolder] puts the check beside the row that already has it. For a
/// batch there is no single holder, so it is simply null and no row is ticked.
///
/// [canReturnToStock] defaults to "only when somebody actually holds this" —
/// offering it otherwise is a button that does nothing. A batch passes it
/// explicitly, because "is anyone holding any of these" is a question about
/// rows the caller can see and this sheet cannot.
Future<AssignStandeeChoice?> showAssignStandeeSheet(
  BuildContext context, {
  required String subject,
  StandeeAssignee? currentHolder,
  String title = 'Assign this standee',
  bool subjectIsCode = true,
  bool? canReturnToStock,
  String returnLabel = 'Return to stock',
}) {
  return showModalBottomSheet<AssignStandeeChoice>(
    context: context,
    backgroundColor: AppColors.surface1,
    isScrollControlled: true,
    showDragHandle: true,
    barrierColor: AppColors.scrim,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => _AssignSheet(
      subject: subject,
      currentHolder: currentHolder,
      title: title,
      subjectIsCode: subjectIsCode,
      canReturnToStock: canReturnToStock ?? (currentHolder != null),
      returnLabel: returnLabel,
    ),
  );
}

class _AssignSheet extends ConsumerWidget {
  const _AssignSheet({
    required this.subject,
    required this.title,
    required this.subjectIsCode,
    required this.canReturnToStock,
    required this.returnLabel,
    this.currentHolder,
  });

  final String subject;
  final String title;
  final bool subjectIsCode;
  final bool canReturnToStock;
  final String returnLabel;
  final StandeeAssignee? currentHolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reps = ref.watch(salesRepsProvider);

    return SafeArea(
      child: ConstrainedBox(
        // Half the screen at most, so the sheet never becomes a full-height
        // wall for a roster of three people, and scrolls when it is longer.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: AppTypography.sizeHeadline,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    // What is being assigned, so an admin who opened the sheet
                    // from the wrong row finds out HERE rather than afterwards.
                    subject,
                    style: TextStyle(
                      fontSize: AppTypography.sizeBody,
                      color: AppColors.textSecondary,
                      // Monospace for a code, where the characters matter one
                      // by one; proportional for a batch label, which is prose.
                      fontFamily: subjectIsCode ? 'monospace' : null,
                      letterSpacing: subjectIsCode ? 1.5 : null,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: reps.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.xxl),
                  child: Center(child: AppLoadingIndicator()),
                ),
                error: (_, __) => Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "Couldn't load the rep list.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppTypography.sizeBody,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppButton.secondary(
                        label: 'Try again',
                        onPressed: () => ref.invalidate(salesRepsProvider),
                      ),
                    ],
                  ),
                ),
                data: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.lg),
                        child: Text(
                          'No staff accounts yet. Grant someone the SALES_REP '
                          'role first, then come back.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppTypography.sizeBody,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final rep = list[i];
                          return _RepRow(
                            rep: rep,
                            isCurrent: rep.id == currentHolder?.id,
                            onTap: () =>
                                Navigator.of(context).pop(AssignToRep(rep)),
                          );
                        },
                      ),
              ),
            ),

            // Only when there is something to return.
            if (canReturnToStock) ...[
              const Divider(height: 1, color: AppColors.surface2),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: AppButton.secondary(
                  key: const ValueKey('standee_unassign'),
                  label: returnLabel,
                  icon: Icons.undo,
                  onPressed: () =>
                      Navigator.of(context).pop(const UnassignStandee()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RepRow extends StatelessWidget {
  const _RepRow({
    required this.rep,
    required this.isCurrent,
    required this.onTap,
  });

  final SalesRepSummary rep;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = rep.person.secondaryLabel;

    return ListTile(
      onTap: onTap,
      title: Text(
        rep.person.label,
        style: const TextStyle(
          fontSize: AppTypography.sizeBody,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        // The role rides along because the roster is capability-based: an ADMIN
        // or a MODEL_ARTIST can use /rep too and both appear here, so without
        // it an admin cannot tell why their own name is on the list.
        [if (secondary != null) secondary, _roleLabel(rep.role)].join(' · '),
        style: const TextStyle(
          fontSize: AppTypography.sizeLabel,
          color: AppColors.textMuted,
        ),
      ),
      trailing: isCurrent
          ? const Icon(Icons.check, color: AppColors.royalGold, size: 20)
          : null,
    );
  }
}

String _roleLabel(UserRole role) => switch (role) {
      UserRole.admin => 'Admin',
      UserRole.modelArtist => 'Model artist',
      UserRole.salesRep => 'Sales rep',
      // Unreachable — the endpoint never returns a plain USER — but the switch
      // stays exhaustive so a new role is a compile error here, not a blank.
      UserRole.user => 'User',
    };
