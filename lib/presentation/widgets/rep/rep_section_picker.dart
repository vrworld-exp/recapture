// lib/presentation/widgets/rep/rep_section_picker.dart
//
// "Which section of the menu does this dish go in?", with the answer the rep
// usually needs — a section that does not exist yet — built into the same
// control.
//
// WHY THE CREATE IS IN THE PICKER AND NOT ONLY IN THE MANAGER. A rep activates
// a restaurant and it has NO sections: `activate` seeds none. So the first dish
// of every visit is added by someone who must invent "Starters" before they can
// file anything into it. Sending them to a separate manager screen to do that,
// and back, at the exact moment they are holding a plate and a phone, is how
// every dish ends up in Uncategorized instead — which is precisely the state
// this widget exists to end. The last item in the list is therefore an action,
// not a value.
//
// THE SELECTION IS THE CALLER'S. This widget never holds the chosen id: it
// reports changes and renders what it is given, so the add-dish form and the
// dish editor each keep their own dirty-tracking. What it DOES own is the
// create — the dialog, the duplicate-name error, and telling the notifier —
// because all three are the same on both screens.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_category.dart';

/// The sentinel the "New section…" row carries.
///
/// A String rather than a null or an empty id, and deliberately one no
/// ObjectId can equal: `null` is already taken — it is Uncategorized, a real
/// and selectable answer — so the action needs a value of its own that cannot
/// collide with a category id arriving from the server.
const String _kNewSectionValue = '__rep_new_section__';

/// The section a dish sits in, plus a way to make one.
///
/// [value] is the currently chosen category id; null is Uncategorized.
class RepSectionPicker extends ConsumerStatefulWidget {
  const RepSectionPicker({
    super.key,
    required this.catalogId,
    required this.categories,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.fieldKey,
  });

  final String catalogId;
  final List<CatalogCategory> categories;
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  /// Key for the dropdown itself, so each host screen keeps the widget key its
  /// own tests already look for.
  final Key? fieldKey;

  @override
  ConsumerState<RepSectionPicker> createState() => _RepSectionPickerState();
}

class _RepSectionPickerState extends ConsumerState<RepSectionPicker> {
  /// True while the create round trip is in flight. The field is disabled for
  /// it: a second "New section…" tap mid-create would open a second dialog over
  /// the first.
  bool _creating = false;

  Future<void> _handle(String? selected) async {
    if (selected != _kNewSectionValue) {
      widget.onChanged(selected);
      return;
    }

    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NewSectionDialog(catalogId: widget.catalogId),
    );
    if (name == null || !mounted) return;

    setState(() => _creating = true);
    try {
      final created = await ref
          .read(repCategoriesProvider(widget.catalogId).notifier)
          .create(name);
      if (!mounted) return;
      // SELECTED IMMEDIATELY. The rep typed this name in order to put the dish
      // in it; making them choose it again from the reopened list is a step
      // that exists only because the code was easier to write that way.
      widget.onChanged(created.id);
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_createFailureText(failure.code))),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A value the list does not carry — a section deleted on another device, or
    // renamed a moment ago — would make DropdownButton assert. Falling back to
    // Uncategorized shows the truth the dish will have if saved, rather than
    // crashing the screen over a stale id.
    final known = widget.categories.any((c) => c.id == widget.value);
    final enabled = widget.enabled && !_creating;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String?>(
          key: widget.fieldKey,
          initialValue: known ? widget.value : null,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          // WHAT THE CLOSED FIELD SHOWS, spelled out rather than defaulted.
          // Without this, `items` is built a SECOND time to render the current
          // selection, so every option's text and key exists twice in the tree —
          // which makes the field briefly claim "New section…" as a value and
          // makes any test that taps an option by name ambiguous. One entry per
          // item, in the same order, is the contract.
          selectedItemBuilder: (context) => [
            const Text('Uncategorized'),
            for (final category in widget.categories)
              Text(category.name, overflow: TextOverflow.ellipsis),
            // The action is never a selection, so it needs no closed-state
            // rendering — only its slot, to keep the two lists aligned.
            const SizedBox.shrink(),
          ],
          items: [
            const DropdownMenuItem<String?>(
              key: ValueKey('rep_section_option_none'),
              value: null,
              child: Text('Uncategorized'),
            ),
            for (final category in widget.categories)
              DropdownMenuItem<String?>(
                key: ValueKey('rep_section_option_${category.id}'),
                value: category.id,
                child: Text(category.name, overflow: TextOverflow.ellipsis),
              ),
            const DropdownMenuItem<String?>(
              key: ValueKey('rep_section_option_new'),
              value: _kNewSectionValue,
              child: Row(
                children: [
                  Icon(Icons.add, size: 18, color: AppColors.mirageRed),
                  SizedBox(width: AppSpacing.sm),
                  Text(
                    'New section…',
                    style: TextStyle(color: AppColors.mirageRed),
                  ),
                ],
              ),
            ),
          ],
          onChanged: enabled ? _handle : null,
        ),
        if (widget.categories.isEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            // The honest reading of an empty list, and the nudge out of it.
            // Without this the rep sees a picker with one option and concludes
            // sections are not a thing on this screen.
            'This menu has no sections yet. Dishes without one show under '
            '"Uncategorized" on the public page.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted, height: 1.4),
          ),
        ],
      ],
    );
  }
}

/// OUR words for a create failure. Never the server's own message — it does not
/// know the rep is standing in the restaurant it is about.
String _createFailureText(String code) => switch (code) {
      'DUPLICATE_NAME' => 'This menu already has a section with that name.',
      'CATALOG_NOT_FOUND' =>
        'You can no longer edit this restaurant. Ask for access again.',
      'OFFLINE' => "You're offline. Check your connection and try again.",
      _ => "Couldn't add that section. Try again in a moment.",
    };

/// Asks for a name, and nothing else.
///
/// Position is not offered: the server appends, and a rep choosing where a
/// section sits before it has anything in it is a decision made too early. The
/// manager screen reorders once there is something to look at.
class _NewSectionDialog extends StatefulWidget {
  const _NewSectionDialog({required this.catalogId});

  final String catalogId;

  @override
  State<_NewSectionDialog> createState() => _NewSectionDialogState();
}

class _NewSectionDialogState extends State<_NewSectionDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: const Text('New menu section'),
        content: Form(
          key: _formKey,
          child: TextFormField(
            key: const ValueKey('rep_new_section_name'),
            controller: _controller,
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
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('rep_new_section_create'),
            onPressed: _submit,
            child: const Text('Create'),
          ),
        ],
      );
}
