// lib/presentation/screens/rep/rep_sections_screen.dart
//
// `/rep/catalogs/:id/sections` — the menu's structure, on the restaurant's
// behalf: create, rename, reorder, delete.
//
// WHY A REP MAY RESHAPE A MENU AT ALL. The delegated category routes used to be
// read-only, on the reasoning that sections outlive the visit and so belong to
// the owner. That reasoning assumed the sections EXISTED. `activate` seeds none,
// so a rep-signed restaurant starts with zero: the picker in the dish editor
// could only ever choose Uncategorized, every dish landed in one unnamed heap,
// and the public page rendered as a flat list with nothing to navigate. The
// owner could fix it — by signing in, later, and rebuilding the structure of a
// menu somebody else had just spent an hour filling.
//
// SO THE SCREEN IS DELIBERATELY PLAIN. It is the owner's category manager
// without the parts that need a second visit to understand: no bulk moves, no
// per-section sync detail, no undo stack. What is here is the four verbs, each
// with the one confirmation that matters — and delete says how many dishes it
// is about to move, because deleting a grouping on someone else's menu must
// never look like it deleted the dishes in it.
//
// EVERY WRITE IS THE NOTIFIER'S. This file has no HTTP and no optimism of its
// own: [RepCategoriesNotifier] owns which mutations move first (only the drag)
// and how a failure rolls back, so the rep and the owner surfaces cannot drift
// on the answer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_category.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_message.dart';

class RepSectionsScreen extends ConsumerStatefulWidget {
  const RepSectionsScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<RepSectionsScreen> createState() => _RepSectionsScreenState();
}

class _RepSectionsScreenState extends ConsumerState<RepSectionsScreen> {
  /// True while a write is in flight. The list is not disabled for it — a rep
  /// reading the menu while one row saves is fine — but the row that is saving
  /// stops accepting a second tap.
  String? _busyId;

  RepCategoriesNotifier get _notifier =>
      ref.read(repCategoriesProvider(widget.catalogId).notifier);

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _failureText(String code) => switch (code) {
        'DUPLICATE_NAME' => 'This menu already has a section with that name.',
        'ID_SET_MISMATCH' =>
          'The sections changed on another device. Pull to refresh.',
        'NOT_FOUND' => 'That section is already gone.',
        'CATALOG_NOT_FOUND' =>
          'You can no longer edit this restaurant. Ask for access again.',
        'OFFLINE' => "You're offline. Check your connection and try again.",
        _ => 'Something went wrong. Try again in a moment.',
      };

  Future<void> _create() async {
    final name = await _askForName(title: 'New menu section');
    if (name == null) return;
    try {
      await _notifier.create(name);
      _report('Added "$name".');
    } on CatalogFailure catch (failure) {
      _report(_failureText(failure.code));
    }
  }

  Future<void> _rename(CatalogCategory category) async {
    final name = await _askForName(
      title: 'Rename section',
      initial: category.name,
    );
    if (name == null || name == category.name) return;

    setState(() => _busyId = category.id);
    try {
      await _notifier.rename(category.id, name);
    } on CatalogFailure catch (failure) {
      _report(_failureText(failure.code));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _delete(CatalogCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text('Delete "${category.name}"?'),
        content: Text(
          // THE DISHES SURVIVE, and the sentence says so before the tap rather
          // than after it. `productCount` is the live count; the server may move
          // archived dishes too, so the result is reported separately.
          category.productCount == 0
              ? 'This section is empty. The menu keeps every dish it has.'
              : category.productCount == 1
                  ? 'Its 1 dish moves to Uncategorized. Nothing is deleted.'
                  : 'Its ${category.productCount} dishes move to '
                      'Uncategorized. Nothing is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('rep_section_delete_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = category.id);
    try {
      final moved = await _notifier.delete(category.id);
      _report(
        moved == 0
            ? 'Deleted "${category.name}".'
            : moved == 1
                ? 'Deleted "${category.name}". 1 dish moved to Uncategorized.'
                : 'Deleted "${category.name}". $moved dishes moved to '
                    'Uncategorized.',
      );
    } on CatalogFailure catch (failure) {
      _report(_failureText(failure.code));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    try {
      await _notifier.reorder(oldIndex, newIndex);
    } on CatalogFailure catch (failure) {
      // The notifier has already rolled the row back and re-read; all that is
      // left is to say why it sprang back.
      _report(_failureText(failure.code));
    }
  }

  /// One text field, used by both create and rename.
  Future<String?> _askForName({
    required String title,
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final formKey = GlobalKey<FormState>();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          void submit() {
            if (!formKey.currentState!.validate()) return;
            Navigator.of(dialogContext).pop(controller.text.trim());
          }

          return AlertDialog(
            backgroundColor: AppColors.surface1,
            title: Text(title),
            content: Form(
              key: formKey,
              child: TextFormField(
                key: const ValueKey('rep_section_name_field'),
                controller: controller,
                autofocus: true,
                maxLength: kMaxCategoryNameLength,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Section name',
                  hintText: 'e.g. Starters',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Give the section a name.'
                    : null,
                onFieldSubmitted: (_) => submit(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('rep_section_name_save'),
                onPressed: submit,
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(repCategoriesProvider(widget.catalogId));

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Menu sections')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('rep_add_section_fab'),
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New section'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.mirageRed,
          backgroundColor: AppColors.surface1,
          onRefresh: () => _notifier.refresh(),
          child: listAsync.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (error, _) => CatalogMessage(
              icon: Icons.category_outlined,
              title: "We couldn't load the sections",
              body: isDelegationGone(error)
                  ? 'This restaurant is no longer assigned to you. Go back to '
                      'your restaurants to see what is.'
                  : _failureText(
                      error is CatalogFailure ? error.code : 'UNKNOWN',
                    ),
              actionLabel: 'Try again',
              onAction: () =>
                  ref.invalidate(repCategoriesProvider(widget.catalogId)),
            ),
            data: _body,
          ),
        ),
      ),
    );
  }

  Widget _body(CatalogCategoryList list) {
    if (list.categories.isEmpty) {
      // Scrollable, so pull-to-refresh still works on an empty menu.
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const SizedBox(height: AppSpacing.xxl),
          CatalogMessage(
            icon: Icons.category_outlined,
            title: 'No sections yet',
            body: 'Sections are the headings on the public page — Starters, '
                'Mains, Drinks. Every dish without one shows under '
                '"Uncategorized".',
            actionLabel: 'Add the first section',
            onAction: _create,
          ),
        ],
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        // Clear of the FAB, so the last row is never trapped under it.
        AppSpacing.xxl * 3,
      ),
      itemCount: list.categories.length + 1,
      // The uncategorized footer is not draggable: it is not a row on the
      // server, so there is no position for a drag to write.
      onReorder: _reorder,
      itemBuilder: (context, index) {
        if (index == list.categories.length) {
          return _UncategorizedFooter(
            key: const ValueKey('rep_uncategorized_footer'),
            count: list.uncategorizedCount,
          );
        }
        final category = list.categories[index];
        return _SectionRow(
          key: ValueKey(category.id),
          index: index,
          category: category,
          busy: _busyId == category.id,
          onRename: () => _rename(category),
          onDelete: () => _delete(category),
        );
      },
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    super.key,
    required this.index,
    required this.category,
    required this.busy,
    required this.onRename,
    required this.onDelete,
  });

  final int index;
  final CatalogCategory category;
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final count = category.productCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.only(
            left: AppSpacing.md,
            right: AppSpacing.xs,
          ),
          leading: ReorderableDragStartListener(
            index: index,
            child: const Icon(Icons.drag_handle, color: AppColors.textMuted),
          ),
          title: Text(category.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            count == 0
                ? 'Empty'
                : count == 1
                    ? '1 dish'
                    : '$count dishes',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
          trailing: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey('rep_section_rename_${category.id}'),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      tooltip: 'Rename',
                      onPressed: onRename,
                    ),
                    IconButton(
                      key: ValueKey('rep_section_delete_${category.id}'),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Delete',
                      onPressed: onDelete,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The uncategorized bucket, shown even at zero.
///
/// Always rendered so it does not appear and disappear as dishes move, and
/// visibly NOT a section: no drag handle, no rename, no delete. It is a null
/// `categoryId` on the dishes, and giving it row affordances would invite a rep
/// to try to manage something that does not exist.
class _UncategorizedFooter extends StatelessWidget {
  const _UncategorizedFooter({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(color: AppColors.surface2),
          ),
          child: Row(
            children: [
              const Icon(Icons.inbox_outlined,
                  size: 20, color: AppColors.textMuted),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  count == 0
                      ? 'Uncategorized — empty'
                      : count == 1
                          ? 'Uncategorized — 1 dish'
                          : 'Uncategorized — $count dishes',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      );
}
