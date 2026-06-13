// lib/presentation/screens/capture/pre_capture_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/checklist_item.dart';
import '../../widgets/app_button.dart';
import '../../widgets/checklist_item_tile.dart';

/// Pre-capture checklist. The user acknowledges each required item before the
/// Start CTA enables and navigates into the capture flow.
///
/// Acknowledgment state lives in local widget state only — no global state
/// management is needed for a single transient screen.
class PreCaptureScreen extends StatefulWidget {
  const PreCaptureScreen({super.key});

  @override
  State<PreCaptureScreen> createState() => _PreCaptureScreenState();
}

class _PreCaptureScreenState extends State<PreCaptureScreen> {
  final Set<String> _checkedIds = <String>{};

  /// True once every required item has been acknowledged. A returning user who
  /// arrives with all items pre-checked would see the CTA enabled immediately.
  bool get _allRequiredChecked => defaultChecklistItems
      .where((item) => item.isRequired)
      .every((item) => _checkedIds.contains(item.id));

  void _setChecked(ChecklistItem item, bool checked) {
    setState(() {
      if (checked) {
        _checkedIds.add(item.id);
      } else {
        _checkedIds.remove(item.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
        title: Text('Before you start', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Text(
                'Confirm each item below for the best capture results.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            // Scrollable list keeps the CTA pinned and on-screen even on small
            // devices or in landscape.
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: defaultChecklistItems.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final item = defaultChecklistItems[index];
                  return ChecklistItemTile(
                    item: item,
                    isChecked: _checkedIds.contains(item.id),
                    onToggle: (checked) => _setChecked(item, checked),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                label: 'Start Capture',
                // Null disables the button (greyed state) until every required
                // item is acknowledged.
                onPressed: _allRequiredChecked
                    ? () => context.go(AppRoutes.permissions)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
