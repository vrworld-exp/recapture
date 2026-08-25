// lib/presentation/widgets/offline_retry_modal.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../platform/haptics.dart';
import '../../utils/analytics.dart';
import 'app_button.dart';

/// Which screen surfaced the offline modal — used for analytics.
enum OfflineSource { auth, projectsHub }

extension OfflineSourceAnalytics on OfflineSource {
  String get analyticsValue => switch (this) {
        OfflineSource.auth => 'auth',
        OfflineSource.projectsHub => 'projects_hub',
      };
}

/// Module-level guard so a repeated connectivity failure can never stack a
/// second modal on top of the first.
bool _isModalShown = false;

/// Presents the blocking offline/retry modal. Returns only after a successful
/// retry (the modal is non-dismissible otherwise). A no-op if one is already
/// showing.
Future<void> showOfflineRetryModal(
  BuildContext context, {
  required Future<void> Function() onRetry,
  required OfflineSource source,
}) async {
  if (_isModalShown) return;
  _isModalShown = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false, // cannot tap outside to dismiss
      barrierColor: AppColors.scrim,
      builder: (dialogContext) => OfflineRetryModal(
        onRetry: onRetry,
        source: source,
        onDismissed: () => Navigator.of(dialogContext).pop(),
      ),
    );
  } finally {
    _isModalShown = false;
  }
}

/// Blocking modal shown when the app is offline or a network call fails.
///
/// Dismissal is driven solely by a successful [onRetry] — a raw connectivity
/// event never closes it, because connectivity alone does not prove the API is
/// reachable.
class OfflineRetryModal extends StatefulWidget {
  const OfflineRetryModal({
    required this.onRetry,
    required this.source,
    this.onDismissed,
    super.key,
  });

  /// Caller-supplied retry. Must throw on failure.
  final Future<void> Function() onRetry;

  /// Called after a successful retry so the caller can close the modal.
  final VoidCallback? onDismissed;

  final OfflineSource source;

  @override
  State<OfflineRetryModal> createState() => _OfflineRetryModalState();
}

enum _ModalState { idle, retrying, failed }

class _OfflineRetryModalState extends State<OfflineRetryModal> {
  _ModalState _state = _ModalState.idle;

  /// Single in-flight guard — only one retry runs at a time, so a rapid
  /// double-tap is ignored.
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    Haptics.appeared();
    Analytics.logEvent('offline_modal_shown', {
      'source_screen': widget.source.analyticsValue,
      'device_type': _deviceType,
    });
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  Future<void> _onRetry() async {
    if (_inFlight) return; // double-tap guard
    _inFlight = true;
    Haptics.retryTapped();
    setState(() => _state = _ModalState.retrying);
    try {
      await widget.onRetry();
      Analytics.logEvent('offline_modal_retry', {
        'source_screen': widget.source.analyticsValue,
        'result': 'success',
      });
      if (!mounted) return;
      widget.onDismissed?.call();
    } catch (_) {
      Analytics.logEvent('offline_modal_retry', {
        'source_screen': widget.source.analyticsValue,
        'result': 'failed',
      });
      await Haptics.failed();
      if (!mounted) return;
      setState(() => _state = _ModalState.failed);
    } finally {
      _inFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRetrying = _state == _ModalState.retrying;

    return PopScope(
      // Block the back button while the modal is up — cannot escape to a
      // broken screen behind it.
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.surface1,
        insetPadding: const EdgeInsets.all(AppSpacing.xxl),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.mirageRed.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.cloud_off,
                  color: AppColors.mirageRed,
                  size: 28,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                "You're offline",
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'We could not reach the network. Check your connection '
                'and try again.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (_state == _ModalState.failed) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  "Still can't connect. Please try again in a moment.",
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                label: 'Retry',
                icon: Icons.refresh,
                isLoading: isRetrying,
                onPressed: _onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
