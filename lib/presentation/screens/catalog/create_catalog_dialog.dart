// lib/presentation/screens/catalog/create_catalog_dialog.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/catalog/catalog_feedback.dart';

/// Hand-synced with the create schema in
/// `recapture-api/src/validation/catalogSchemas.ts` (there is no shared package —
/// see AGENTS.md §0.1). Enforced here only so an over-long name is caught before
/// the round-trip; the server remains the authority.
const int kCatalogNameMaxLength = 120;
const int kBusinessNameMaxLength = 120;

/// Asks for the catalog's name and creates it, resolving to the created
/// [Catalog] — or to null if the user backed out.
///
/// Plain [showDialog] rather than a bottom sheet: this is the same modal on a
/// phone and in a desktop browser, and the catalog gets created from the web
/// build as often as from the APK. `AlertDialog(scrollable: true)` is what keeps
/// the fields reachable when an on-screen keyboard takes half the viewport.
///
/// The dialog stays dismissible right up until Create is pressed, and not after
/// — see the PopScope in [CreateCatalogDialog].
Future<Catalog?> showCreateCatalogDialog(BuildContext context) =>
    showDialog<Catalog>(
      context: context,
      barrierColor: AppColors.scrim,
      // Tap-outside routes through maybePop, so the PopScope below still gets to
      // veto it while the request is in flight.
      barrierDismissible: true,
      builder: (_) => const CreateCatalogDialog(),
    );

/// The create-catalog form (feature 1).
///
/// The request is issued from INSIDE the dialog rather than by the caller after
/// it pops, so a failure can reappear next to the fields with what the user
/// typed still in them. Popping first and awaiting afterwards would throw the
/// typed name away on every retry.
class CreateCatalogDialog extends ConsumerStatefulWidget {
  const CreateCatalogDialog({super.key});

  @override
  ConsumerState<CreateCatalogDialog> createState() => _CreateCatalogDialogState();
}

class _CreateCatalogDialogState extends ConsumerState<CreateCatalogDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _businessNameController = TextEditingController();

  bool _submitting = false;

  /// The last failure's owner-safe sentence, shown inline. Cleared on every new
  /// attempt so a stale message never sits under a request that is succeeding.
  String? _failureMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _businessNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final businessName = _businessNameController.text.trim();

    setState(() {
      _submitting = true;
      _failureMessage = null;
    });

    // Resolved before the await: ref belongs to this State, and the create must
    // still land in the notifier even if the dialog goes away underneath it.
    final notifier = ref.read(catalogProvider.notifier);

    try {
      final created = await notifier.create(
        name: _nameController.text.trim(),
        // Absent, not empty — the server schema is strict and rejects a blank
        // businessName.
        businessName: businessName.isEmpty ? null : businessName,
      );
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // Mapped from the CODE, from the one catalog table — the offline
        // sentinel included. Anything that is not a CatalogFailure has no code
        // and falls through to the same generic sentence.
        _failureMessage = error is CatalogFailure
            ? CatalogFeedback.failureText(error)
            : CatalogFeedback.textForCode(null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // Creating is idempotent server-side, but a dialog that vanished mid-flight
      // would leave the user unsure whether it happened. Block back / tap-outside
      // only while the request is actually running.
      canPop: !_submitting,
      child: AlertDialog(
        backgroundColor: AppColors.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        // Scrolls the dialog rather than clipping it once the keyboard is up —
        // the phone case; harmless in a browser.
        scrollable: true,
        title: Text('Create your catalog', style: theme.textTheme.titleLarge),
        content: SizedBox(
          // Clamped by the dialog's own max width, so this is a cap for wide
          // browser windows, not a floor that would overflow a small phone.
          width: 360,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'This is the storefront customers open when they scan your QR '
                  'code. You can rename it later.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.textSecondary, height: 1.5),
                ),
                const SizedBox(height: AppSpacing.xxl),
                AppTextField(
                  label: 'Catalog name',
                  hint: 'e.g. Cafe Mocha',
                  controller: _nameController,
                  autofocus: true,
                  enabled: !_submitting,
                  maxLength: kCatalogNameMaxLength,
                  textInputAction: TextInputAction.next,
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Give your catalog a name.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  label: 'Business name (optional)',
                  hint: 'Shown under the catalog name',
                  controller: _businessNameController,
                  enabled: !_submitting,
                  maxLength: kBusinessNameMaxLength,
                  textInputAction: TextInputAction.done,
                  // Enter submits from the last field — the desktop-web
                  // expectation, and a convenience on a phone keyboard.
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_failureMessage != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    _failureMessage!,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: AppColors.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            // Null while submitting: the theme greys it, and the PopScope would
            // veto the pop anyway.
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          AppButton(
            label: 'Create catalog',
            isFullWidth: false,
            isLoading: _submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
