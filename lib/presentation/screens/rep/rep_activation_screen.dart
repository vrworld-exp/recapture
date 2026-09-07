// lib/presentation/screens/rep/rep_activation_screen.dart
//
// The screen a rep uses standing at a table: a code in, a live catalog out.
//
// FOUR STEPS, AND THE ORDER IS THE DESIGN.
//   1. CODE — scan (where the build can) or type. Preflighted before anything
//      else is asked for, so a rep never fills in a restaurant's whole profile
//      against a standee that turns out to be taken.
//   2. DETAILS — name and phone, using the SIGN-IN SCREEN'S OWN phone widget
//      and validator. Not a similar one: the number typed here becomes the
//      restaurant's sign-in identity, and the two have to normalise identically
//      or the owner lands on an empty second account.
//   3. CONFIRM — the number read back, and an explicit tap. See the comment on
//      RepActivationState.pendingRequest for why this step earns its place.
//   4. DONE — the live link, and the number again, so a wrong one is caught
//      while the rep is still at the table rather than by a support call.
//
// No HTTP and no parsing here — both live in RepRepository. Failures are read
// by CODE and answered with this screen's own copy; a backend sentence never
// reaches a rep.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_activation_notifier.dart';
import '../../../application/rep/rep_capabilities.dart';
import '../../../application/rep/rep_catalogs_notifier.dart';
import '../../../application/rep/rep_standees_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/rep_repository.dart';
import '../../../domain/auth/auth_input_validators.dart';
import '../../../domain/entities/country_code.dart';
import '../../../domain/entities/qr_standee.dart';
import '../../../domain/entities/rep_activation.dart';
import '../../../domain/rep/qr_code_input.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/country_code_picker.dart';
import 'rep_qr_scanner_screen.dart';

class RepActivationScreen extends ConsumerStatefulWidget {
  const RepActivationScreen({super.key, this.initialCode});

  /// A code carried in from the deep link `?code=` — the rep scanned the
  /// standee with their OS camera, landed on the resolver's "not live yet"
  /// page, and tapped through.
  ///
  /// A PREFILL, NOT A COMMAND. It fills the field and nothing else: the rep
  /// still taps Continue, the preflight still runs, and the value is still
  /// editable. A link that activated on arrival would let a mis-scan start a
  /// one-shot, irreversible action with no human in the loop.
  final String? initialCode;

  @override
  ConsumerState<RepActivationScreen> createState() =>
      _RepActivationScreenState();
}

class _RepActivationScreenState extends ConsumerState<RepActivationScreen> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  CountryCode _country = kDefaultCountryCode;
  String? _codeError;
  String? _nameError;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    // Normalised on the way in, so a full scanned URL prefills as the bare code
    // — the same string the sticker shows. An unparseable value is dropped
    // rather than shown: it could only produce an error the rep did not cause.
    final incoming = widget.initialCode;
    if (incoming != null) {
      final normalized = QrCodeInput.normalize(incoming);
      if (normalized != null) _codeController.text = normalized;
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// The E.164 form — dial code plus the national digits, exactly as the OTP
  /// screen composes it. The restaurant will later sign in with this string.
  String get _e164 => '${_country.dialCode}${_phoneController.text.trim()}';

  /// Open the scanner, and treat what it returns exactly as if the rep had
  /// typed it — same field, same validation, same Continue.
  ///
  /// IT DOES NOT AUTO-SUBMIT. The scanner already guarantees the value is one
  /// of our codes, so submitting here would work; it is still wrong. A scan of
  /// the WRONG STANDEE is the mistake this flow cannot take back later, and the
  /// rep's own eyes on the filled field are the only check against it. This is
  /// the same reasoning the `?code=` deep link follows — a prefill, never a
  /// command — and the two paths stay identical on purpose.
  Future<void> _scanCode() async {
    final code = await showRepQrScanner(context);
    if (code == null || !mounted) return;
    setState(() {
      _codeController.text = code;
      _codeError = null;
    });
  }

  /// Fills the field from the rep's own assigned stock.
  ///
  /// A PREFILL, NEVER A SUBMIT — the same contract [_scanCode] and the `?code=`
  /// deep link both keep. A recommendation is the app's guess at which standee
  /// the rep is holding, and the rep's eyes on the filled field are the only
  /// check against activating the wrong one. Tapping it also does not skip the
  /// preflight: the list can be seconds stale, and the server still decides.
  void _pickAssigned(RepStandee standee) {
    setState(() {
      _codeController.text = standee.code;
      _codeError = null;
    });
  }

  Future<void> _submitCode() async {
    final raw = _codeController.text;
    if (!QrCodeInput.isValid(raw)) {
      setState(() => _codeError = 'Enter the 8-character code on the standee.');
      return;
    }
    setState(() => _codeError = null);
    await ref.read(repActivationProvider.notifier).submitCode(raw);
  }

  void _submitDetails() {
    final name = _nameController.text.trim();
    final phoneError = AuthInputValidators.phone(
      _phoneController.text,
      country: _country,
    );
    setState(() {
      _nameError = name.isEmpty ? "Enter the restaurant's name." : null;
      _phoneError = phoneError;
    });
    if (name.isEmpty || phoneError != null) return;

    final code = ref.read(repActivationProvider).preflight?.code;
    if (code == null) return;

    ref.read(repActivationProvider.notifier).review(
          RepActivationRequest(
            code: code,
            restaurantName: name,
            restaurantPhone: _e164,
          ),
        );
  }

  Future<void> _confirm() async {
    await ref.read(repActivationProvider.notifier).confirm();
    // A fresh activation adds a delegation, so the rep's catalog list is stale.
    // Invalidate rather than reach for the notifier: the list is autoDispose,
    // and this screen is reachable by deep link with no catalogs screen behind
    // it — reading `.notifier` there would BUILD the provider (one request)
    // only to refresh it (a second) and drop both on the floor a tick later.
    // Invalidate refreshes it where it is being watched and is a no-op where it
    // is not, which is exactly right: an unmounted list re-reads on its next
    // open anyway.
    if (ref.read(repActivationProvider).isDone) {
      ref.invalidate(repCatalogsProvider);
    }
  }

  void _restart() {
    _codeController.clear();
    _nameController.clear();
    _phoneController.clear();
    setState(() {
      _codeError = null;
      _nameError = null;
      _phoneError = null;
    });
    ref.read(repActivationProvider.notifier).restart();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(repActivationProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Activate a standee')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: switch (state.step) {
            RepActivationStep.code => _codeStep(state),
            RepActivationStep.details => _detailsStep(state),
            RepActivationStep.confirming => _confirmStep(state),
            RepActivationStep.done => _doneStep(state),
          },
        ),
      ),
    );
  }

  // ── 1. The code ───────────────────────────────────────────────────────────

  Widget _codeStep(RepActivationState state) {
    final canScan = ref.watch(repCapabilitiesProvider).canScan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('Scan or enter the standee code'),
        const SizedBox(height: AppSpacing.sm),
        const _Hint(
          'The 8-character code is printed under the QR square. You can also '
          'paste the full link from a camera scan.',
        ),
        const SizedBox(height: AppSpacing.lg),

        // HIDDEN, not disabled, where the build cannot scan — a disabled button
        // in a browser is a promise the platform can never keep. The capability
        // comes from a provider rather than kIsWeb so one test asserts both
        // renderings; see rep_capabilities.dart.
        if (canScan) ...[
          AppButton.secondary(
            key: const ValueKey('rep_scan_button'),
            label: 'Scan the code',
            icon: Icons.qr_code_scanner,
            onPressed: _scanCode,
          ),
          const SizedBox(height: AppSpacing.md),
        ],

        AppTextField(
          key: const ValueKey('rep_code_field'),
          label: 'Standee code',
          hint: 'ABCD2345',
          controller: _codeController,
          errorText: _codeError,
          autofocus: true,
          textInputAction: TextInputAction.go,
          // Uppercased as typed so the field shows the stored form, matching
          // what is printed on the sticker. The server normalises again — this
          // copy is for the keyboard, never for trust.
          inputFormatters: [UpperCaseTextFormatter()],
          onChanged: (_) {
            if (_codeError != null) setState(() => _codeError = null);
          },
          onFieldSubmitted: (_) => _submitCode(),
        ),
        const SizedBox(height: AppSpacing.md),

        // The standees an admin assigned to this rep, offered as one-tap fills.
        _AssignedStandees(
          codeController: _codeController,
          onPick: _pickAssigned,
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.failure != null) _FailureNote(failure: state.failure!),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          key: const ValueKey('rep_code_continue'),
          label: 'Continue',
          isLoading: state.isBusy,
          onPressed: state.isBusy ? null : _submitCode,
        ),
      ],
    );
  }

  // ── 2. The restaurant ─────────────────────────────────────────────────────

  Widget _detailsStep(RepActivationState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepTitle('Code ${state.preflight?.code ?? ''} is free'),
        const SizedBox(height: AppSpacing.sm),
        const _Hint("Now the restaurant's details."),
        const SizedBox(height: AppSpacing.lg),
        AppTextField(
          key: const ValueKey('rep_name_field'),
          label: 'Restaurant name',
          hint: 'Blue Cafe',
          controller: _nameController,
          errorText: _nameError,
          maxLength: 120,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
        ),
        const SizedBox(height: AppSpacing.md),

        // THE SAME two-part phone input the sign-in screen uses, wired to the
        // SAME validator. A parallel implementation here is how the two
        // normalisations drift, and a drift here strands a restaurant behind an
        // account they cannot reach.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CountryCodeButton(
              country: _country,
              onPressed: () async {
                final picked = await showCountryCodePicker(
                  context,
                  selected: _country,
                );
                if (picked == null || !mounted) return;
                setState(() {
                  _country = picked;
                  _phoneError = null;
                });
              },
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppTextField(
                key: const ValueKey('rep_phone_field'),
                label: 'Restaurant phone',
                hint: '98765 43210',
                controller: _phoneController,
                errorText: _phoneError,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 15,
                onChanged: (_) {
                  if (_phoneError != null) setState(() => _phoneError = null);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        const _Hint(
          'The owner signs in with this number, so it has to be theirs.',
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          key: const ValueKey('rep_details_continue'),
          label: 'Review',
          onPressed: _submitDetails,
        ),
      ],
    );
  }

  // ── 3. The confirmation ───────────────────────────────────────────────────

  Widget _confirmStep(RepActivationState state) {
    final request = state.pendingRequest;
    if (request == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('Check before activating'),
        const SizedBox(height: AppSpacing.sm),
        const _Hint(
          'The owner will sign in with this number. Read it back to them.',
        ),
        const SizedBox(height: AppSpacing.lg),
        _SummaryRow(label: 'Code', value: request.code),
        _SummaryRow(label: 'Restaurant', value: request.restaurantName),
        // The number in EXACTLY the form the restaurant would type at sign-in.
        _SummaryRow(
          label: 'Phone',
          value: request.restaurantPhone,
          emphasis: true,
          valueKey: const ValueKey('rep_confirm_phone'),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (state.failure != null) ...[
          _FailureNote(failure: state.failure!),
          const SizedBox(height: AppSpacing.md),
        ],
        AppButton(
          key: const ValueKey('rep_confirm_activate'),
          label: 'Activate',
          isLoading: state.isBusy,
          onPressed: state.isBusy ? null : _confirm,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton.secondary(
          key: const ValueKey('rep_confirm_edit'),
          label: 'Change details',
          onPressed: state.isBusy
              ? null
              : ref.read(repActivationProvider.notifier).editDetails,
        ),
        if (state.failure?.isCodeUnavailable ?? false) ...[
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            key: const ValueKey('rep_confirm_another_code'),
            label: 'Use another code',
            onPressed: _restart,
          ),
        ],
      ],
    );
  }

  // ── 4. Live ───────────────────────────────────────────────────────────────

  Widget _doneStep(RepActivationState state) {
    final result = state.result!;
    final request = state.pendingRequest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle, color: AppColors.royalGold, size: 40),
        const SizedBox(height: AppSpacing.md),
        const _StepTitle('This standee is live'),
        const SizedBox(height: AppSpacing.lg),
        _SummaryRow(label: 'Link', value: result.publicUrl),
        // The number AGAIN, deliberately. A typo caught here is a two-minute
        // fix at the table; caught later it is a support ticket and a stranded
        // catalog.
        if (request != null)
          _SummaryRow(
            label: 'Owner signs in with',
            value: request.restaurantPhone,
            emphasis: true,
          ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          key: const ValueKey('rep_done_add_dishes'),
          label: 'Add dishes',
          onPressed: () => Navigator.of(context).pop(result.catalogId),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton.secondary(
          label: 'Activate another',
          onPressed: _restart,
        ),
      ],
    );
  }
}

/// Uppercases as the rep types, so the field shows the stored form of the code
/// — the same string printed on the sticker.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      TextEditingValue(
        text: newValue.text.toUpperCase(),
        selection: newValue.selection,
      );
}

// ── Small pieces ────────────────────────────────────────────────────────────

/// The rep's own assigned standees, as one-tap fills for the code field.
///
/// WHY THIS IS ON THE FIRST SCREEN OF THE FLOW. A rep arrives at a table
/// holding a printed sheet and, until now, typed eight characters off it — the
/// one place in the whole flow where a slip produces a live standee on the
/// wrong restaurant. Their assigned stock is the short list of codes it is
/// almost certainly one of, so it belongs exactly where the typing happens.
///
/// SILENT WHEN IT HAS NOTHING TO SAY. A rep with no assignments, or one whose
/// list has not loaded, sees no section at all — not a spinner and not an empty
/// state. This is a shortcut past the text field, and a shortcut that announces
/// its own absence is worse than one that is simply not there; the field above
/// it works regardless. That is also why a load FAILURE renders nothing: it
/// costs the rep a convenience, never the activation.
///
/// Only ACTIVATABLE standees appear ([RepStandeesState.available]). Offering a
/// code that is already live somewhere would be a recommendation whose only
/// outcome is the "already in use" error this feature exists to avoid.
class _AssignedStandees extends ConsumerWidget {
  const _AssignedStandees({required this.codeController, required this.onPick});

  /// Watched, not read: the highlight has to follow the field on every
  /// keystroke, including a code the rep typed by hand that happens to be one
  /// of theirs. A value captured at build time would go stale immediately.
  final TextEditingController codeController;

  final void Function(RepStandee) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(repStandeesProvider).available;
    if (available.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          available.length == 1
              ? 'Your standee'
              : 'Your standees (${available.length})',
          style: const TextStyle(
            fontSize: AppTypography.sizeLabel,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: codeController,
          builder: (_, value, __) {
            final typed = value.text.trim().toUpperCase();
            return Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final standee in available)
                  _StandeeChip(
                    standee: standee,
                    selected: typed == standee.code,
                    onTap: () => onPick(standee),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StandeeChip extends StatelessWidget {
  const _StandeeChip({
    required this.standee,
    required this.selected,
    required this.onTap,
  });

  final RepStandee standee;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.surface2 : AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: InkWell(
        key: ValueKey('rep_standee_chip_${standee.code}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            // The ONE gold accent this section spends: a ring on the chip whose
            // code is in the field, so the rep can see at a glance that the
            // thing they tapped is the thing that will be preflighted.
            border: Border.all(
              color: selected ? AppColors.royalGold : AppColors.surface2,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            standee.code,
            style: TextStyle(
              fontSize: AppTypography.sizeBody,
              fontFamily: 'monospace',
              letterSpacing: 1.5,
              color:
                  selected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: AppTypography.sizeTitle,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: AppTypography.sizeBody,
          color: AppColors.textSecondary,
        ),
      );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.emphasis = false,
    this.valueKey,
  });

  final String label;
  final String value;
  final bool emphasis;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: AppTypography.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              key: valueKey,
              style: TextStyle(
                fontSize: emphasis
                    ? AppTypography.sizeHeadline
                    : AppTypography.sizeBody,
                fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );
}

/// One failure, in THIS screen's words.
///
/// Reads [CatalogFailure.code] and nothing else. The backend's message is
/// owner-safe but it is still the server's sentence: it cannot name the standee
/// in the rep's hand and it never says what to do next.
class _FailureNote extends StatelessWidget {
  const _FailureNote({required this.failure});

  final CatalogFailure failure;

  ({String what, String next}) get _copy => switch (failure.code) {
        RepErrorCodes.codeUnavailable => (
            what: 'That code is already in use.',
            next: 'Use another standee.',
          ),
        RepErrorCodes.codeNotFound => (
            what: 'That code is not one of ours.',
            next: 'Check the characters and try again.',
          ),
        RepErrorCodes.rateLimited => (
            what: 'Too many activations just now.',
            next: 'Wait a few minutes and try again.',
          ),
        // A PERMANENT refusal, not a retryable one — the generic "try again in
        // a moment" would send the rep round a loop that can never succeed.
        // Moving this code would strand the printed URL of a restaurant that is
        // already live, so the only way forward is a different standee.
        RepErrorCodes.sourceCatalogPublished => (
            what: 'That code belongs to a restaurant that is already live.',
            next: 'Use a fresh standee — this one cannot be moved.',
          ),
        RepErrorCodes.resolverNotConfigured => (
            what: 'Activation is not available right now.',
            next: 'Let the team know — this one is on us, not you.',
          ),
        'INVALID_REQUEST' => (
            what: 'Something in the form is not right.',
            next: 'Check the code and the phone number.',
          ),
        'OFFLINE' => (
            what: "You're offline.",
            next: 'Check your connection and try again.',
          ),
        _ => (
            what: 'Something went wrong.',
            next: 'Try again in a moment.',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    return Container(
      key: const ValueKey('rep_failure_note'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: AppColors.textMuted.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            copy.what,
            style: const TextStyle(
              fontSize: AppTypography.sizeBody,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            copy.next,
            style: const TextStyle(
              fontSize: AppTypography.sizeLabel,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
