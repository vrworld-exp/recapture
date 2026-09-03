// lib/presentation/screens/profile/profile_screen.dart
//
// The signed-in user's account screen: avatar, display name, masked contact,
// member-since, and Sign out. A standalone /profile destination the Projects
// app bar go()es to (back is mapped /profile → /projects by flowBackRouteFor).
//
// PII: the contact identifier is a MASK the backend produced — the raw phone /
// email is never shipped to the client at all (recapture-api routes/auth.ts).
// Nothing on this screen goes to analytics beyond the event name + device type
// (plus a mapped `reason` enum on an avatar failure). The avatar URL is a
// short-lived presigned credential and the S3 key is an internal identifier:
// neither is ever logged, tracked, or rendered.
//
// AUTH: the router guard owns "is the user signed in" (app_router.dart guard
// contract) — this screen deliberately does not re-check it. After sign-out the
// guard's refreshListenable bounces every protected route to /auth on its own;
// a manual navigation here would RACE that redirect.
import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        showCupertinoModalPopup;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_info.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/auth_notifier.dart';
import '../../../application/auth/profile_provider.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../data/datasources/avatar_image_picker.dart';
import '../../../dev/dev_log/dev_upload_log.dart';
import '../../../domain/entities/avatar_upload_failure.dart';
import '../../../domain/entities/user_profile.dart';
import '../../../domain/entities/user_role.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/delete_confirmation_modal.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  /// Sign-out in flight. Blocks the button so a double-tap can never fire two
  /// logouts (the best-effort server-side revoke can take a moment against a
  /// cold backend, leaving the button tappable for longer than you'd think).
  bool _signingOut = false;

  /// Display-name save in flight — guards the edit dialog's Save the same way.
  bool _savingName = false;

  /// An avatar change is being SET UP (sheet open, gallery open, confirm open).
  /// Distinct from [avatarUploadingProvider], which covers only the network
  /// leg: this closes the window between the first tap and the request, which
  /// is where a double-tap would otherwise open two pickers.
  bool _changingAvatar = false;

  @override
  void initState() {
    super.initState();
    Analytics.logEvent(AnalyticsEvents.profileScreenOpened, {
      'device_type': _deviceType,
    });
    // Android may have destroyed this activity while the gallery was in front,
    // killing the future that was awaiting the pick. The selection itself
    // survives, parked in the plugin — reclaim it on mount, or the photo the
    // user chose is simply gone with no sign anything happened.
    unawaited(_recoverLostAvatar());
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Profile', style: Theme.of(context).textTheme.titleLarge),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
          // The one BACK behavior — pops the pushed route, or falls back to the
          // mapped previous screen (Projects) for a go()-replaced entry.
          onPressed: () => navigateBack(context),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The identity block is the only part that depends on the fetch.
              // Sign out below is NOT inside this switch — see the comment there.
              Expanded(
                child: SingleChildScrollView(
                  child: switch (profileAsync) {
                    AsyncData(:final value) => _IdentityBlock(
                        profile: value,
                        onEditName: () => _editName(value),
                        onTapAvatar: () => _changeAvatar(value),
                      ),
                    AsyncError() => _ProfileErrorView(
                        onRetry: () =>
                            ref.read(profileProvider.notifier).refresh(),
                      ),
                    _ => const _ProfileSkeleton(),
                  },
                ),
              ),
              // ── Sign out ────────────────────────────────────────────────────
              // ALWAYS enabled, in every state. A user whose profile will not
              // load is exactly the user who most needs to sign out; gating this
              // behind a successful fetch would strand them.
              //
              // Secondary variant with an error-coloured label, NOT mirageRed:
              // red-on-red would fight the primary-CTA rule, and sign-out is
              // destructive rather than primary.
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: _DangerButtonTheme(
                  child: AppButton.secondary(
                    label: 'Sign out',
                    icon: Icons.logout,
                    isLoading: _signingOut,
                    onPressed: _signingOut ? null : _confirmSignOut,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: Text(
                  AppInfo.displayVersion,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sign out ───────────────────────────────────────────────────────────────

  Future<void> _confirmSignOut() async {
    if (_signingOut) return;

    // Platform-adaptive destructive confirm (Material dialog / Cupertino sheet),
    // branching on Theme.of(context).platform so tests can force either side.
    // ANY dismissal resolves false.
    final confirmed = await showDeleteConfirmation(
      context,
      count: 1, // not photo-driven; the signOut copy ignores it
      kind: ConfirmKind.signOut,
    );
    if (!confirmed || !mounted) return;

    setState(() => _signingOut = true);
    Analytics.logEvent(AnalyticsEvents.profileSignOut, {
      'device_type': _deviceType,
    });

    try {
      await ref.read(authProvider.notifier).logout();
    } finally {
      // logout() clears secure storage + the active_session / projects_cache /
      // offline_queue boxes, and the router guard then bounces this protected
      // route to /auth on its own. NO manual navigation here — it would race
      // that redirect and could strand the user on a half-torn-down screen.
      if (mounted) setState(() => _signingOut = false);
    }
  }

  // ── Display name ───────────────────────────────────────────────────────────

  Future<void> _editName(UserProfile profile) async {
    if (_savingName) return;

    final name = await showDialog<String>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (_) => _EditNameDialog(initial: profile.displayName ?? ''),
    );
    if (name == null || !mounted) return;

    setState(() => _savingName = true);
    try {
      // Optimistic with rollback inside the notifier (projects-state
      // convention) — the new name paints before the request resolves.
      await ref.read(profileProvider.notifier).updateDisplayName(name);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save your name. Try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  // ── Profile picture ────────────────────────────────────────────────────────

  /// Tap on the avatar → the platform-adaptive source sheet, then the chosen
  /// action. A cancelled sheet, and a cancelled gallery pick, are both silent
  /// no-ops — neither is an error and neither deserves a snackbar.
  Future<void> _changeAvatar(UserProfile profile) async {
    if (_changingAvatar || ref.read(avatarUploadingProvider)) return;
    setState(() => _changingAvatar = true);
    try {
      final action = await showAvatarActionSheet(
        context,
        canRemove: profile.hasAvatar,
      );
      if (action == null || !mounted) return;

      switch (action) {
        case AvatarAction.choose:
          await _pickAndUploadAvatar();
        case AvatarAction.remove:
          await _confirmRemoveAvatar();
      }
    } finally {
      if (mounted) setState(() => _changingAvatar = false);
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    // Read the notifier BEFORE the gallery round-trip. `ref` belongs to this
    // State and is unusable once it unmounts, but the upload does not belong to
    // the widget — it must survive one. Resolving it up front is what lets the
    // `mounted` checks below guard only the UI.
    final notifier = ref.read(profileProvider.notifier);
    try {
      final picked = await ref.read(avatarImagePickerProvider).pickAvatar();
      if (picked == null) return; // cancelled — silent, and only a cancel

      await _uploadPicked(picked, notifier);
    } catch (error) {
      _reportAvatarFailure(error);
    }
  }

  /// Reclaims and uploads a selection Android parked when it tore this screen
  /// down mid-pick. A no-op on every other platform and in the normal case.
  ///
  /// The RECLAIM half must fail silently. It runs on every mount, unprompted —
  /// the user opened their profile, they did not ask for this — so a probe that
  /// reported its own failure would greet them with an error about a photo they
  /// never chose. Only the upload of a photo actually recovered can raise.
  Future<void> _recoverLostAvatar() async {
    final notifier = ref.read(profileProvider.notifier);

    PickedAvatar? lost;
    try {
      lost = await ref.read(avatarImagePickerProvider).recoverLostAvatar();
    } catch (error, stack) {
      DevUploadLog.instance
          .add('avatar: lost-pick recovery skipped', error: error, stack: stack);
      return;
    }
    if (lost == null) return;

    // Past here a real photo was reclaimed, so a failure IS the user's business.
    try {
      await _uploadPicked(lost, notifier);
    } catch (error) {
      _reportAvatarFailure(error);
    }
  }

  /// The upload leg, shared by the normal pick and the lost-pick recovery.
  ///
  /// Deliberately NOT guarded by `mounted`: the bytes are already chosen and the
  /// notifier outlives this widget, so an unmount between picking and uploading
  /// must not silently discard the user's photo. Only the analytics/snackbar
  /// that follow care whether a screen is still there.
  Future<void> _uploadPicked(PickedAvatar picked, ProfileNotifier notifier) async {
    await notifier.updateAvatar(picked.bytes, contentType: picked.contentType);
    Analytics.logEvent(AnalyticsEvents.profileAvatarUpdated, {
      'device_type': _deviceType,
    });
  }

  Future<void> _confirmRemoveAvatar() async {
    // The same platform-adaptive destructive confirm the rest of the app uses;
    // ANY dismissal resolves false, so a stray tap-outside never removes a
    // picture.
    final confirmed = await showDeleteConfirmation(
      context,
      count: 1, // not photo-driven; the removeAvatar copy ignores it
      kind: ConfirmKind.removeAvatar,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(profileProvider.notifier).removeAvatar();
      Analytics.logEvent(AnalyticsEvents.profileAvatarRemoved, {
        'device_type': _deviceType,
      });
    } catch (error) {
      _reportAvatarFailure(error);
    }
  }

  /// Maps a failure to copy and a `reason` enum. The raw error NEVER reaches
  /// the snackbar (the Screen-9F convention), and never reaches analytics
  /// either — only the mapped bucket does.
  void _reportAvatarFailure(Object error) {
    final reason = error is AvatarUploadException
        ? error.reason
        : AvatarUploadFailure.unknown;

    Analytics.logEvent(AnalyticsEvents.profileAvatarFailed, {
      'reason': _avatarFailureReason(reason),
      'device_type': _deviceType,
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_avatarFailureMessage(reason))),
    );
  }
}

/// User-facing copy per failure. Every branch is actionable and none of them
/// mentions a status code, a key, a URL, or a file path.
String _avatarFailureMessage(AvatarUploadFailure reason) {
  switch (reason) {
    case AvatarUploadFailure.tooLarge:
      return 'That photo is too large. Try a different one.';
    case AvatarUploadFailure.unsupportedType:
      return 'That file type is not supported. Choose a JPG or PNG.';
    case AvatarUploadFailure.rateLimited:
      return "You've changed your photo a lot. Try again later.";
    case AvatarUploadFailure.network:
      return "Couldn't reach the server. Check your connection.";
    case AvatarUploadFailure.unknown:
      return "Couldn't update your photo. Try again.";
  }
}

/// The analytics `reason` enum value — snake_case, matching the event doc.
String _avatarFailureReason(AvatarUploadFailure reason) {
  switch (reason) {
    case AvatarUploadFailure.tooLarge:
      return 'too_large';
    case AvatarUploadFailure.unsupportedType:
      return 'unsupported_type';
    case AvatarUploadFailure.rateLimited:
      return 'rate_limited';
    case AvatarUploadFailure.network:
      return 'network';
    case AvatarUploadFailure.unknown:
      return 'unknown';
  }
}

// ── Avatar source sheet ──────────────────────────────────────────────────────

/// What the user picked from the avatar sheet.
enum AvatarAction { choose, remove }

/// Platform-idiomatic "change your picture" sheet — Material bottom sheet on
/// Android, [CupertinoActionSheet] on iOS/macOS.
///
/// Branches on `Theme.of(context).platform` (NOT `Platform.isIOS`) so tests can
/// force either side, exactly like [showDeleteConfirmation].
///
/// *Remove photo* is present ONLY when [canRemove] — offering to remove a
/// picture that does not exist is a dead option, and worse, a destructive-styled
/// one. Any dismissal resolves null (a no-op).
Future<AvatarAction?> showAvatarActionSheet(
  BuildContext context, {
  required bool canRemove,
}) {
  final theme = Theme.of(context);
  final platform = theme.platform;
  final isCupertino =
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

  // Synchronous (no await before the present call) so no BuildContext crosses
  // an async gap — the delete-modal convention.
  if (isCupertino) {
    return showCupertinoModalPopup<AvatarAction>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Profile photo'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(AvatarAction.choose),
            child: const Text('Choose photo'),
          ),
          if (canRemove)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(AvatarAction.remove),
              child: const Text('Remove photo'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true, // safe default emphasis
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  return showModalBottomSheet<AvatarAction>(
    context: context,
    backgroundColor: AppColors.surface1,
    barrierColor: AppColors.scrim,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(
              Icons.photo_library_outlined,
              color: AppColors.textSecondary,
            ),
            title: Text('Choose photo', style: theme.textTheme.bodyLarge),
            onTap: () => Navigator.of(ctx).pop(AvatarAction.choose),
          ),
          if (canRemove)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.error),
              title: Text(
                'Remove photo',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: AppColors.error),
              ),
              onTap: () => Navigator.of(ctx).pop(AvatarAction.remove),
            ),
        ],
      ),
    ),
  );
}

/// Re-colours a secondary [AppButton]'s label + icon to [AppColors.error].
///
/// A wrapping DefaultTextStyle/IconTheme would NOT work: OutlinedButton applies
/// the outlined-button theme's own `foregroundColor` (textPrimary) inside
/// itself, which wins. So the override has to happen in the button theme, and
/// only there — border, radius, sizing and typography still resolve from the
/// ambient theme, so this can never drift off-theme.
class _DangerButtonTheme extends StatelessWidget {
  const _DangerButtonTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: (theme.outlinedButtonTheme.style ?? const ButtonStyle())
              .copyWith(
            // Keeps the theme's muted disabled colour — only the ENABLED
            // label/icon turns red.
            foregroundColor: WidgetStateProperty.resolveWith<Color>(
              (states) => states.contains(WidgetState.disabled)
                  ? AppColors.textMuted
                  : AppColors.error,
            ),
          ),
        ),
      ),
      child: child,
    );
  }
}

// ── Identity block (avatar + name + contact + info card) ─────────────────────

class _IdentityBlock extends ConsumerWidget {
  const _IdentityBlock({
    required this.profile,
    required this.onEditName,
    required this.onTapAvatar,
  });

  final UserProfile profile;
  final VoidCallback onEditName;
  final VoidCallback onTapAvatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Staff-only: a plain USER must see no role text at all.
    final isStaff = ref.watch(isStaffProvider);
    final uploading = ref.watch(avatarUploadingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xxxl),
        Center(
          child: _Avatar(
            initials: profile.initials,
            // Loading and failure both resolve to null → initials. A profile
            // that will not render a picture is never worse than a plain one.
            imageBytes: ref.watch(avatarBytesProvider).valueOrNull,
            uploading: uploading,
            onTap: onTapAvatar,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // ── Display name (tap anywhere on the row, or the pencil, to edit) ────
        InkWell(
          onTap: onEditName,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    profile.hasDisplayName
                        ? profile.displayName!
                        : 'Add your name',
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: profile.hasDisplayName
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                const Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),

        // ── Masked contact — the row is HIDDEN entirely when there is none ────
        // (no placeholder: an empty "—" would read as a broken account).
        if (profile.contactMasked != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                profile.contactChannel == 'email'
                    ? Icons.mail_outline
                    : Icons.phone_outlined,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  profile.contactMasked!,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: AppSpacing.xxl),

        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                label: 'Member since',
                value: _formatMemberSince(profile.createdAt),
              ),
              if (isStaff) ...[
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Role',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                    _RolePill(role: profile.role),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A gold-ringed circle holding, in this order of preference: the user's
/// profile picture, their initials, or a person glyph. Tapping it opens the
/// avatar source sheet.
///
/// THEME: the 1.5px royalGold ring remains the screen's ONE royalGold element
/// (the 2–3% budget). The picture goes INSIDE that ring — no second gold accent,
/// no gold camera badge, no gold progress arc.
class _Avatar extends StatelessWidget {
  const _Avatar({
    this.initials,
    this.imageBytes,
    this.uploading = false,
    this.onTap,
  });

  final String? initials;

  /// The decoded picture, or null for "no picture / could not load one".
  ///
  /// BYTES, not the snapshot's presigned URL. The browser build cannot fetch
  /// that URL (cross-origin to a bucket with no CORS) and it expires in about an
  /// hour, so fetching through our own API is the only display path that works
  /// on web and native alike. See AccountRepository.fetchAvatarBytes.
  final Uint8List? imageBytes;

  /// An avatar change is in flight: dim the picture and overlay a spinner. The
  /// REST of the screen stays interactive — Sign out especially.
  final bool uploading;

  final VoidCallback? onTap;

  static const double _size = 96;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          children: [
            Container(
              width: _size,
              height: _size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface1,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.royalGold, width: 1.5),
              ),
              // Clipped so the photo can never paint over the ring stroke.
              child: ClipOval(
                child: Opacity(
                  opacity: uploading ? 0.35 : 1,
                  child: _content(context),
                ),
              ),
            ),
            if (uploading)
              const Positioned.fill(
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            // The affordance that the avatar is tappable. textSecondary on
            // surface2 — deliberately NOT gold (see the theme note above).
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                  color: AppColors.surface2,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.photo_camera_outlined,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// First non-null wins: picture → initials → person glyph.
  Widget _content(BuildContext context) {
    final bytes = imageBytes;
    if (bytes == null || bytes.isEmpty) return _fallback(context);

    return Image.memory(
      bytes,
      width: _size,
      height: _size,
      fit: BoxFit.cover,
      gaplessPlayback: true, // swapping pictures must not flash the fallback
      // Undecodable bytes degrade to initials, never to a broken-image glyph.
      errorBuilder: (context, error, stack) => _fallback(context),
    );
  }

  Widget _fallback(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Center(
        child: initials == null
            ? const Icon(
                Icons.person_outline,
                size: 40,
                color: AppColors.textSecondary,
              )
            : Text(
                initials!,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
      ),
    );
  }
}

/// Staff-only role badge. Styled like [AppStatusPill] but standalone: that
/// widget is typed on `ProjectStatus` and derives its label/colour from the
/// project-status extension, so it cannot express a user role.
class _RolePill extends StatelessWidget {
  const _RolePill({required this.role});

  final UserRole role;

  @override
  Widget build(BuildContext context) {
    final label = switch (role) {
      UserRole.admin => 'Admin',
      UserRole.modelArtist => 'Model artist',
      // Unreachable today — the pill is rendered under an isStaff gate and a
      // SALES_REP is not staff. Present because the switch must stay TOTAL:
      // leaving it out is a compile error, and a wildcard would hide the next
      // role added.
      UserRole.salesRep => 'Sales rep',
      UserRole.user => 'User',
    };
    const color = AppColors.royalGold;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // BOTH sides flex. Two unconstrained Texts in a spaceBetween Row have
    // nowhere to put the excess when the card is narrow (a small window, a
    // large text scale, or a long value like 'September 2026') — it overflows
    // and paints the stripes. Flexible + ellipsis degrades instead.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// 'March 2026'. Local-time month/year — no l10n framework in this repo, so the
/// month names are resolved in Dart (the existing convention).
String _formatMemberSince(DateTime utc) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final local = utc.toLocal();
  return '${months[local.month - 1]} ${local.year}';
}

// ── Loading / error states ───────────────────────────────────────────────────

/// Skeleton for the avatar/name/contact block, matching the `_SkeletonList`
/// style on the Projects screen (surface2 boxes, no shimmer).
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        SizedBox(height: AppSpacing.xxxl),
        _SkeletonBox(width: 96, height: 96, circle: true),
        SizedBox(height: AppSpacing.xl),
        _SkeletonBox(width: 160, height: 18),
        SizedBox(height: AppSpacing.md),
        _SkeletonBox(width: 120, height: 14),
        SizedBox(height: AppSpacing.xxl),
        _SkeletonBox(width: double.infinity, height: 56),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    this.circle = false,
  });

  final double width;
  final double height;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(AppRadius.xs),
      ),
    );
  }
}

/// Inline retry. Deliberately NOT full-screen: Sign out stays visible and
/// enabled below it.
class _ProfileErrorView extends StatelessWidget {
  const _ProfileErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.huge),
      child: Column(
        children: [
          const Icon(
            Icons.person_off_outlined,
            size: 40,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            "Couldn't load your profile.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton.secondary(
            label: 'Retry',
            isFullWidth: false,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

// ── Edit-name dialog ─────────────────────────────────────────────────────────

/// Small single-field editor. Pops the TRIMMED name, or null on any dismissal.
/// Bounds mirror the server's rule (1–60 chars after trimming) so an obviously
/// invalid name isn't sent; the backend still re-validates.
class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.initial});

  final String initial;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      title: Text('Your name', style: theme.textTheme.titleLarge),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 60, // mirrors the server's DISPLAY_NAME_MAX_LENGTH
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: const InputDecoration(hintText: 'e.g. John D'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return; // the server rejects it too — don't round-trip
    Navigator.of(context).pop(name);
  }
}
