// lib/presentation/screens/catalog/business_profile_screen.dart
//
// The business profile behind the storefront (features 58, 59, 60, 2).
//
// What this screen is careful about, in order of how badly it goes wrong:
//   • It never claims a field is public when it is not. Which fields reach
//     customers is the SERVER's answer ([BusinessProfile.publicFields]), read
//     per field — hardcoding the list here would go stale the first time the
//     publish worker learns to carry another one, and the direction it goes
//     stale in is "we told them it was live and it wasn't".
//   • It never implies a saved edit is already live. Every write here is a draft
//     edit; branding reaches the public page on Publish (feature 57).
//   • It never re-uploads an image it has already uploaded. A commit that fails
//     after a successful upload retries the COMMIT.
//   • It never loses typed work silently — in-app back, browser back and tab
//     close all warn.
//
// This is NOT the account screen. `profile_screen.dart` edits the USER (avatar,
// display name, masked contact) and lives in a different key space; the business
// profile lives on the Catalog. The two stay separate.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/business_profile_notifier.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/datasources/product_image_picker.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../domain/catalog/business_profile_validators.dart';
import '../../../domain/entities/business_profile.dart';
import '../../../platform/unsaved_changes.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

/// Width at or above which the form splits into two columns.
///
/// From the CONSTRAINTS, never `kIsWeb` — the same rule and the same number as
/// the product editor, so a narrow browser window gets the phone layout and a
/// wide tablet gets the desktop one.
const double kBusinessProfileTwoColumnWidth = 900;

/// Whether the profile form currently holds unsaved edits.
///
/// A provider rather than screen state because the ROUTER reads it: the
/// browser's back button is a router event, and go_router's `onExit` has no
/// access to the screen's State. Kept honest by the screen, which clears it on
/// dispose.
final businessProfileDirtyProvider = StateProvider<bool>((ref) => false);

/// The `onExit` guard for `/catalog/settings`, and the in-app back guard.
///
/// Returns true when it is safe to leave. Lifted out of the screen for the same
/// reason the editor's is: the router calls it with no widget in hand.
Future<bool> confirmDiscardProfileEdits(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!container.read(businessProfileDirtyProvider)) return true;

  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Discard your changes?'),
      content: const Text(
        "You have edits that haven't been saved. Leaving now loses them.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep editing'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child:
              const Text('Discard', style: TextStyle(color: AppColors.error)),
        ),
      ],
    ),
  );

  if (discard != true) return false;
  container.read(businessProfileDirtyProvider.notifier).state = false;
  setUnsavedChangesWarning(false);
  return true;
}

class BusinessProfileScreen extends ConsumerWidget {
  const BusinessProfileScreen({super.key});

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
          onPressed: () async {
            if (!await confirmDiscardProfileEdits(context)) return;
            if (!context.mounted) return;
            navigateBack(context);
          },
        ),
        title: Text(
          'Business profile',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "We couldn't load your profile",
          body: error is CatalogFailure
              ? CatalogFeedback.failureText(error)
              : CatalogFeedback.textForCode(null),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(businessProfileProvider),
        ),
        // No catalog yet is the first-run state, not an error. There is nothing
        // to brand until the catalog exists, and creating one belongs to the
        // catalog shell rather than here.
        data: (profile) => profile == null
            ? const CatalogMessage(
                icon: Icons.storefront_outlined,
                title: 'No catalog yet',
                body: 'Create your catalog first — the business profile is the '
                    'branding that wraps it.',
              )
            : _ProfileForm(
                // Keyed by the catalog id ALONE, deliberately. The profile
                // object is replaced on every branding commit, and keying on
                // `updatedAt` would rebuild the form — throwing away text the
                // user had typed but not saved — every time a logo finished
                // uploading. The controllers are the user's; only a SAVE
                // re-seeds them.
                key: ValueKey<String>(profile.id),
                profile: profile,
              ),
      ),
    );
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  const _ProfileForm({super.key, required this.profile});

  final BusinessProfile profile;

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  final _formKey = GlobalKey<FormState>();

  late final Map<String, TextEditingController> _fields = {
    'name': TextEditingController(text: widget.profile.name),
    'businessName':
        TextEditingController(text: widget.profile.businessName ?? ''),
    'phone': TextEditingController(text: _contact?.phone ?? ''),
    'email': TextEditingController(text: _contact?.email ?? ''),
    'address': TextEditingController(text: _contact?.address ?? ''),
    // Shown without its scheme — that is how a business writes its own address
    // on a card. The scheme is put back at save time by [normalizeWebsite].
    'website': TextEditingController(
      text: _contact?.website == null ? '' : displayWebsite(_contact!.website!),
    ),
    'instagram': TextEditingController(text: _socials?.instagram ?? ''),
    'facebook': TextEditingController(text: _socials?.facebook ?? ''),
    'youtube': TextEditingController(text: _socials?.youtube ?? ''),
    'whatsapp': TextEditingController(text: _socials?.whatsapp ?? ''),
  };

  /// The last SAVED value of each field. The dirty check compares against this
  /// rather than against the entity, so a field the user typed into and then
  /// typed back out of is correctly not dirty — and so a successful save can
  /// move the baseline without rebuilding the form.
  late Map<String, String> _initial = {
    for (final entry in _fields.entries) entry.key: entry.value.text,
  };

  bool _saving = false;
  CatalogFailure? _saveError;

  /// The container, captured while the element is alive.
  ///
  /// `ref` is unusable from `dispose()` — flutter_riverpod tears it down with
  /// the element — and this state DOES have to clear the dirty flag on the way
  /// out, or the router's guard keeps blocking a form that no longer exists.
  late final ProviderContainer _container =
      ProviderScope.containerOf(context, listen: false);

  BusinessContact? get _contact => widget.profile.contact;
  BusinessSocials? get _socials => widget.profile.contact?.socials;

  @override
  void initState() {
    super.initState();
    // Touched here so the late field resolves while the element is certainly
    // mounted, rather than on its first use — which could be dispose().
    _container;
    for (final controller in _fields.values) {
      controller.addListener(_onFieldChanged);
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller
        ..removeListener(_onFieldChanged)
        ..dispose();
    }
    // The screen is leaving; whatever was typed is gone either way, and a
    // browser prompt left armed would fire on every later navigation.
    _publishDirty(false);
    super.dispose();
  }

  bool get _isDirty =>
      _fields.entries.any((e) => e.value.text != _initial[e.key]);

  void _onFieldChanged() {
    final dirty = _isDirty;
    if (dirty != _container.read(businessProfileDirtyProvider)) {
      _publishDirty(dirty);
    }
    // The save button and the per-field "changed" marks both read this.
    if (mounted) setState(() {});
  }

  void _publishDirty(bool dirty) {
    _container.read(businessProfileDirtyProvider.notifier).state = dirty;
    // The one exit the app cannot intercept: closing the browser tab. No-op on
    // native, where the PopScope below is the whole story.
    setUnsavedChangesWarning(dirty);
  }

  String _text(String key) => _fields[key]!.text;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final messenger = CatalogFeedback.of(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });

    // The whole contact block, always — the server REPLACES it rather than
    // merging, which is exactly what makes clearing one field possible. A delta
    // here would silently wipe every field it omitted.
    final socials = BusinessSocials(
      instagram: trimToNull(_text('instagram')),
      facebook: trimToNull(_text('facebook')),
      youtube: trimToNull(_text('youtube')),
      whatsapp: trimToNull(_text('whatsapp')),
    );
    final contact = BusinessContact(
      phone: trimToNull(_text('phone')),
      email: trimToNull(_text('email')),
      address: trimToNull(_text('address')),
      website: normalizeWebsite(_text('website')),
      socials: socials.isEmpty ? null : socials,
    );

    try {
      await ref.read(businessProfileProvider.notifier).save(
            name: _text('name').trim(),
            businessName: trimToNull(_text('businessName')),
            contact: contact,
          );
      if (!mounted) return;
      _publishDirty(false);
      CatalogFeedback.confirm(
        messenger,
        'Profile saved. These changes go live the next time you publish.',
      );
      setState(() {
        _saving = false;
        // The baseline moves to what was just saved rather than to the server's
        // echo of it: the two agree, and re-seeding from the response would
        // fight a user who started typing again while the save was in flight.
        _initial = {
          for (final entry in _fields.entries) entry.key: entry.value.text,
        };
      });
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The system back gesture and the Android hardware button. The browser's
      // back button does NOT come through here — that is the router's onExit —
      // and closing a tab comes through neither, which is what the platform
      // seam is for.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!await confirmDiscardProfileEdits(context)) return;
        if (!context.mounted) return;
        navigateBack(context);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn =
              constraints.maxWidth >= kBusinessProfileTwoColumnWidth;
          final branding = _BrandingPanel(profile: widget.profile);
          final fields = _fieldColumn(context);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _PublishReachBanner(),
                    const SizedBox(height: AppSpacing.xxl),
                    if (twoColumn)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: branding),
                          const SizedBox(width: AppSpacing.xxl),
                          Expanded(flex: 3, child: fields),
                        ],
                      )
                    else ...[
                      branding,
                      const SizedBox(height: AppSpacing.xxl),
                      fields,
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _fieldColumn(BuildContext context) {
    final profile = widget.profile;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Field(
            profile: profile,
            path: 'name',
            changed: _text('name') != _initial['name'],
            child: AppTextField(
              label: 'Storefront name',
              controller: _fields['name'],
              enabled: !_saving,
              maxLength: kMaxCatalogNameLength,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.organizationName],
              validator: validateCatalogName,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Field(
            profile: profile,
            path: 'businessName',
            changed: _text('businessName') != _initial['businessName'],
            child: AppTextField(
              label: 'Legal business name (optional)',
              controller: _fields['businessName'],
              enabled: !_saving,
              maxLength: kMaxBusinessNameLength,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.organizationName],
              validator: validateBusinessName,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          _SectionLabel(label: 'How customers reach you'),
          const SizedBox(height: AppSpacing.lg),
          _Field(
            profile: profile,
            path: 'contact.phone',
            changed: _text('phone') != _initial['phone'],
            child: AppTextField(
              label: 'Phone (optional)',
              controller: _fields['phone'],
              enabled: !_saving,
              maxLength: kMaxContactPhoneLength,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.telephoneNumber],
              validator: validatePhone,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Field(
            profile: profile,
            path: 'contact.email',
            changed: _text('email') != _initial['email'],
            child: AppTextField(
              label: 'Email (optional)',
              controller: _fields['email'],
              enabled: !_saving,
              maxLength: kMaxContactEmailLength,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              validator: validateEmail,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Field(
            profile: profile,
            path: 'contact.address',
            changed: _text('address') != _initial['address'],
            child: AppTextField(
              label: 'Address (optional)',
              controller: _fields['address'],
              enabled: !_saving,
              maxLength: kMaxContactAddressLength,
              maxLines: 3,
              minLines: 2,
              keyboardType: TextInputType.streetAddress,
              textInputAction: TextInputAction.newline,
              autofillHints: const [AutofillHints.fullStreetAddress],
              validator: validateAddress,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Field(
            profile: profile,
            path: 'contact.website',
            changed: _text('website') != _initial['website'],
            child: AppTextField(
              label: 'Website (optional)',
              hint: 'mystore.in',
              controller: _fields['website'],
              enabled: !_saving,
              // Not maxLength: the bound applies to the value that is STORED,
              // and this field shows the value without its scheme. The
              // validator checks the normalised form instead.
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: const [AutofillHints.url],
              validator: validateWebsite,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          _SectionLabel(label: 'Social links'),
          const SizedBox(height: AppSpacing.lg),
          for (final social in const [
            ('instagram', 'Instagram', 'contact.socials.instagram'),
            ('facebook', 'Facebook', 'contact.socials.facebook'),
            ('youtube', 'YouTube', 'contact.socials.youtube'),
          ]) ...[
            _Field(
              profile: profile,
              path: social.$3,
              changed: _text(social.$1) != _initial[social.$1],
              child: AppTextField(
                label: '${social.$2} (optional)',
                controller: _fields[social.$1],
                enabled: !_saving,
                maxLength: kMaxSocialLinkLength,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                validator: (value) => validateSocial(value, social.$2),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          _Field(
            profile: profile,
            path: 'contact.socials.whatsapp',
            changed: _text('whatsapp') != _initial['whatsapp'],
            child: AppTextField(
              label: 'WhatsApp number (optional)',
              controller: _fields['whatsapp'],
              enabled: !_saving,
              maxLength: kMaxWhatsappLength,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.telephoneNumber],
              validator: validateWhatsapp,
            ),
          ),
          if (_saveError != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _SaveError(failure: _saveError!),
          ],
          const SizedBox(height: AppSpacing.xxl),
          AppButton(
            label: _saving ? 'Saving…' : 'Save profile',
            isLoading: _saving,
            // Disabled with nothing to save: a button that posts an identical
            // profile still bumps the draft revision server-side, which lights
            // up "unpublished changes" for a change nobody made.
            onPressed: _isDirty && !_saving ? _save : null,
          ),
        ],
      ),
    );
  }
}

// ── Reach labelling ─────────────────────────────────────────────────────────

/// One field, with an honest note about how far it travels.
///
/// The note is read PER FIELD from [BusinessProfile.publicFields], which the
/// server owns. Anything not in that list is ReCapture-only — including fields
/// Mirage's restaurant record has room for (`website`, `socialLinks`) but whose
/// public page does not render yet. Saying "saved, not shown publicly" about a
/// field that later goes live costs one stale sentence; saying the reverse tells
/// a business their phone number is on their storefront when it is not.
class _Field extends StatelessWidget {
  const _Field({
    required this.profile,
    required this.path,
    required this.child,
    this.changed = false,
  });

  final BusinessProfile profile;

  /// The dotted path this field writes — must match the server's own spelling
  /// in `PUBLIC_PROFILE_FIELDS`.
  final String path;

  final Widget child;
  final bool changed;

  @override
  Widget build(BuildContext context) {
    final isPublic = profile.isPublic(path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Icon(
              isPublic ? Icons.public : Icons.lock_outline,
              size: 13,
              color: isPublic ? AppColors.success : AppColors.textMuted,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                isPublic
                    ? 'Shown on your public page after you publish.'
                    : 'Saved in ReCapture. Not shown on your public page yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isPublic ? AppColors.success : AppColors.textMuted,
                    ),
              ),
            ),
            if (changed) const _ChangedDot(),
          ],
        ),
      ],
    );
  }
}

class _ChangedDot extends StatelessWidget {
  const _ChangedDot();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: AppSpacing.sm),
        child: Text(
          'Unsaved',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.warning),
        ),
      );
}

/// The one sentence the whole screen hangs on: nothing here is live yet.
class _PublishReachBanner extends ConsumerWidget {
  const _PublishReachBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Server-derived. The badge is never recomputed by diffing anything here —
    // an edit bumps `draftRevision` on the server and this reads the result.
    final pending = ref.watch(
      catalogProvider
          .select((c) => c.valueOrNull?.hasUnpublishedChanges ?? false),
    );

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: (pending ? AppColors.warning : AppColors.textMuted)
              .withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            pending ? Icons.schedule : Icons.info_outline,
            size: 16,
            color: pending ? AppColors.warning : AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              pending
                  ? 'Your catalog has draft changes. Everything on this screen '
                      'goes live the next time you publish.'
                  : 'Changes on this screen go live the next time you publish.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: Theme.of(context).textTheme.titleMedium,
      );
}

class _SaveError extends StatelessWidget {
  const _SaveError({required this.failure});

  final CatalogFailure failure;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, size: 16, color: AppColors.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                // OUR sentence for the code, from the one table — never the
                // server's own message, never Mirage's prose, never an HTTP
                // status. Same words the toasts use.
                CatalogFeedback.failureText(failure),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.error, height: 1.4),
              ),
            ),
          ],
        ),
      );
}

// ── Branding ────────────────────────────────────────────────────────────────

class _BrandingPanel extends StatelessWidget {
  const _BrandingPanel({required this.profile});

  final BusinessProfile profile;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel(label: 'Branding'),
          const SizedBox(height: AppSpacing.lg),
          _BrandingSlotField(
            profile: profile,
            slot: BrandingSlot.logo,
            path: 'logoUrl',
            title: 'Logo',
            // The one branding field customers see: the publish worker writes it
            // as the Mirage restaurant icon.
            help: 'Square works best. Shown as your storefront icon.',
            url: profile.logoUrl,
            aspectRatio: 1,
          ),
          const SizedBox(height: AppSpacing.xxl),
          _BrandingSlotField(
            profile: profile,
            slot: BrandingSlot.cover,
            path: 'coverImageUrl',
            title: 'Cover image',
            help: 'A wide banner for the top of your catalog.',
            url: profile.coverImageUrl,
            aspectRatio: 16 / 9,
          ),
        ],
      );
}

/// One branding slot: preview, pick, progress, and a commit-only retry.
class _BrandingSlotField extends ConsumerWidget {
  const _BrandingSlotField({
    required this.profile,
    required this.slot,
    required this.path,
    required this.title,
    required this.help,
    required this.url,
    required this.aspectRatio,
  });

  final BusinessProfile profile;
  final BrandingSlot slot;
  final String path;
  final String title;
  final String help;
  final String? url;
  final double aspectRatio;

  /// Picks an image and runs the two-step upload.
  ///
  /// Bytes, never a `dart:io` File — the picker already has one web-safe path
  /// and this reuses it rather than adding a second.
  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final messenger = CatalogFeedback.of(context);
    final notifier = ref.read(businessProfileProvider.notifier);

    final PickedProductImage? picked;
    try {
      picked = await ref.read(productImagePickerProvider).pickProductImage();
    } on ProductImagePickException catch (error) {
      // The user's problem to fix, and it is fixable — say which of the three it
      // was rather than "upload failed".
      CatalogFeedback.confirm(messenger, error.message);
      return;
    }
    if (picked == null) return; // cancelled

    await notifier.uploadBranding(
      slot,
      picked.bytes,
      contentType: picked.contentType,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(businessProfileProvider.notifier);

    return ValueListenableBuilder<BrandingUpload>(
      valueListenable: notifier.uploadOf(slot),
      builder: (context, upload, _) {
        final theme = Theme.of(context);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.bodyLarge),
            const SizedBox(height: AppSpacing.sm),
            AspectRatio(
              aspectRatio: aspectRatio,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface1,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: AppColors.royalGold.withValues(alpha: 0.2),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (url != null && url!.isNotEmpty)
                      Image.network(
                        url!,
                        // No crop step: the image is stored as picked, and the
                        // public page decides its own framing. A crop tool here
                        // would be a promise about a layout we do not own.
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            _BrandingPlaceholder(title: title),
                      )
                    else
                      _BrandingPlaceholder(title: title),
                    if (upload.isBusy)
                      Container(
                        color: AppColors.scrim,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const AppLoadingIndicator(),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              upload.step == BrandingUploadStep.uploading
                                  ? 'Uploading…'
                                  : 'Saving…',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: AppButton.secondary(
                    label: url == null ? 'Upload $title' : 'Replace',
                    onPressed: upload.isBusy ? null : () => _pick(context, ref),
                  ),
                ),
                if (upload.canRetryCommit) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      // The bytes are already in the bucket. Only the pointer
                      // failed, so this retries the COMMIT — asking for the file
                      // again would make the user pay for our failure twice.
                      label: 'Retry saving',
                      onPressed: () => notifier.retryCommit(slot),
                    ),
                  ),
                ],
              ],
            ),
            if (upload.error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _SaveError(failure: upload.error!),
            ],
            const SizedBox(height: AppSpacing.xs),
            Text(
              help,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xs),
            _ReachNote(isPublic: profile.isPublic(path)),
          ],
        );
      },
    );
  }
}

class _ReachNote extends StatelessWidget {
  const _ReachNote({required this.isPublic});

  final bool isPublic;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(
            isPublic ? Icons.public : Icons.lock_outline,
            size: 13,
            color: isPublic ? AppColors.success : AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              isPublic
                  ? 'Shown on your public page after you publish.'
                  : 'Saved in ReCapture. Not shown on your public page yet.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isPublic ? AppColors.success : AppColors.textMuted,
                  ),
            ),
          ),
        ],
      );
}

class _BrandingPlaceholder extends StatelessWidget {
  const _BrandingPlaceholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surface2,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined,
                size: 28, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'No $title yet',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      );
}
