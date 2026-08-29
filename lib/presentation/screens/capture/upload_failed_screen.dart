// lib/presentation/screens/capture/upload_failed_screen.dart
//
// Screen 9F — Upload Failed. The destination when an upload attempt fails. It
// explains WHY in friendly, actionable terms and offers recovery:
//   • Retry — re-attempt the upload with the EXISTING captures (no re-capture, no
//     new session), shown ONLY for retryable failures.
//   • Back to Projects — leave to the Projects list with the project preserved
//     (resumable later); clears the flow from the back stack.
//
// The captured session is NEVER touched here — a failure does not delete it, and
// neither action does either (only the pipeline's own resumable-status marking).
// The screen consumes a MAPPED [UploadErrorCategory] (never a raw error): the copy,
// the retryable classification, and any shown code all derive from the category, so
// no stack trace / server body / token / path / PII can surface. Raw detail is
// logged via diagnostics at the failure site (the uploading screen), not here.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/capture_level_session.dart';
import '../../../application/upload/upload_flow.dart';
import '../../../dev/dev_log/dev_upload_log.dart';
import '../../../domain/upload/upload_failure.dart';
import '../../../utils/analytics.dart';
import '../../../utils/app_env.dart';
import '../../widgets/app_button.dart';
import '../../../utils/platform_name.dart';

class UploadFailedScreen extends ConsumerStatefulWidget {
  const UploadFailedScreen({super.key, required this.failure});

  /// The MAPPED failure category (never a raw error). A missing/garbled route
  /// extra resolves to [UploadErrorCategory.unknown] before it reaches here.
  final UploadErrorCategory failure;

  @override
  ConsumerState<UploadFailedScreen> createState() => _UploadFailedScreenState();
}

class _UploadFailedScreenState extends ConsumerState<UploadFailedScreen> {
  /// Single-flight guard so a double-tap yields exactly one retry / navigation.
  bool _navigating = false;

  static String get _deviceType => appPlatformName;

  String get _sessionId =>
      ref.read(captureLevelSessionProvider)?.sessionId ?? '';

  UploadErrorCategory get _category => widget.failure;

  /// Retry is offered only when the failure is retryable AND there is a session to
  /// re-upload — a missing session makes retry impossible, so we route to Projects.
  bool get _canRetry => _category.retryable && _sessionId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    Analytics.logEvent(AnalyticsEvents.uploadFailedViewed, {
      'session_id': _sessionId,
      'phase': 'upload',
      'error_category': _category.wireName,
      'retryable': _category.retryable,
      'device_type': _deviceType,
    });
  }

  /// Re-attempts the upload by re-entering the uploading screen, which re-subscribes
  /// to the pipeline (resume/restart is the pipeline's concern). Reuses the existing
  /// captures + session — never re-captures, never creates a new session. `go`
  /// replaces the route, so repeated failures return to 9F without stacking.
  void _onRetry() {
    if (_navigating || !_canRetry) return;
    _navigating = true;
    Analytics.logEvent(AnalyticsEvents.uploadRetryTapped, {
      'session_id': _sessionId,
      'error_category': _category.wireName,
      'device_type': _deviceType,
    });
    // A failed flow is terminal — start() replaces it with a fresh run over
    // the SAME captures (installed synchronously, so the uploading screen
    // binds to the new flow, not the failed one's last snapshot).
    ref.read(uploadFlowProvider.notifier).start();
    context.go(AppRoutes.uploading);
  }

  /// Leaves to the Projects list. The project stays resumable (the pipeline's
  /// failed/draft marking is untouched); `go` clears the upload flow from the back
  /// stack so back does not re-enter the failed attempt.
  void _onBackToProjects() {
    if (_navigating) return;
    _navigating = true;
    Analytics.logEvent(AnalyticsEvents.uploadFailedBackToProjects, {
      'session_id': _sessionId,
      'error_category': _category.wireName,
      'device_type': _deviceType,
    });
    context.go(AppRoutes.projects);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final content = _contentFor(_category);
    return PopScope(
      // Back = Back to Projects (the safe exit), never a silent re-entry.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBackToProjects();
      },
      child: Scaffold(
        backgroundColor: AppColors.bgPrimary,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: Text('Upload failed', style: textTheme.titleLarge),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                key: const Key('upload_failed_9f'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      size: 64, color: AppColors.error),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    content.title,
                    style: textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    content.message,
                    key: const Key('upload_failed_message'),
                    style: textTheme.bodyMedium
                        ?.copyWith(color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // MAPPED support reference only — never a raw error.
                  Text(
                    'Error code: ${_category.code}',
                    key: const Key('upload_failed_code'),
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  // Retry only for retryable failures with a session; otherwise
                  // Back to Projects is the primary action (no Retry that would
                  // deterministically fail again).
                  if (_canRetry) ...[
                    AppButton(
                      key: const Key('upload_failed_retry'),
                      label: 'Retry upload',
                      icon: Icons.refresh,
                      onPressed: _onRetry,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton.secondary(
                      key: const Key('upload_failed_back'),
                      label: 'Back to Projects',
                      onPressed: _onBackToProjects,
                    ),
                  ] else
                    AppButton(
                      key: const Key('upload_failed_back'),
                      label: 'Back to Projects',
                      onPressed: _onBackToProjects,
                    ),
                  // DEV ONLY: the flow's step-by-step timeline (with the raw
                  // error behind the mapped code above). Same compile-time
                  // flavor gate as the Dev Tools section; renders nothing
                  // when no flow has logged, so the privacy contract of this
                  // screen is unchanged outside a dev investigation.
                  if (!kAppEnvironment.isProduction) ...[
                    const SizedBox(height: AppSpacing.xl),
                    const _DevLogButton(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Friendly, actionable copy per category (presentation only). Non-technical;
  /// no raw detail. `auth` guides to signing in again (handled by the app's auth
  /// guard on return to Projects); the rest explain what happened + next step.
  static _FailureContent _contentFor(UploadErrorCategory c) => switch (c) {
        UploadErrorCategory.network => const _FailureContent(
            title: "Couldn't connect",
            message: 'Your photos are safe on this device. Check your internet '
                'connection and try again.',
          ),
        UploadErrorCategory.server => const _FailureContent(
            title: 'Upload service is busy',
            message:
                'Something went wrong on our side. Your photos are safe — please '
                'try again in a moment.',
          ),
        UploadErrorCategory.auth => const _FailureContent(
            title: 'Session expired',
            message:
                'Your sign-in expired, so the upload was stopped. Your photos are '
                'safe — go back and sign in again to upload.',
          ),
        UploadErrorCategory.validation => const _FailureContent(
            title: "Photos couldn't be processed",
            message:
                'Some of this capture could not be uploaded. Your project is '
                'saved — you may need to retake it before uploading again.',
          ),
        UploadErrorCategory.quota => const _FailureContent(
            title: 'Upload limit reached',
            message:
                "You've reached your current upload limit. Your photos are saved "
                'and will be here when you can upload again.',
          ),
        UploadErrorCategory.unknown => const _FailureContent(
            title: 'Upload failed',
            message:
                "Something went wrong and the upload didn't finish. Your photos "
                'are safe on this device — you can try again.',
          ),
      };
}

/// The title + body for a failure category (presentation copy).
class _FailureContent {
  const _FailureContent({required this.title, required this.message});
  final String title;
  final String message;
}

/// DEV-ONLY entry point to the upload flow's diagnostic timeline. Renders
/// nothing while the log is empty (so tests and untouched sessions see the
/// unchanged 9F); otherwise a muted button that opens the log sheet. Rebuilt
/// by the log's own ChangeNotifier.
class _DevLogButton extends StatelessWidget {
  const _DevLogButton();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DevUploadLog.instance,
      builder: (context, _) {
        final log = DevUploadLog.instance;
        if (log.isEmpty) return const SizedBox.shrink();
        return TextButton.icon(
          key: const Key('upload_failed_dev_logs'),
          onPressed: () => _showSheet(context),
          icon: const Icon(Icons.terminal, size: 18),
          label: Text('Dev logs (${log.entries.length})'),
          style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
        );
      },
    );
  }

  void _showSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgPrimary,
      builder: (_) => const _DevLogSheet(),
    );
  }
}

/// The scrollable raw timeline + Copy all / Clear. Raw error text is shown
/// here BY DESIGN — this sheet exists only in dev-flavor builds.
class _DevLogSheet extends StatelessWidget {
  const _DevLogSheet();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: AnimatedBuilder(
            animation: DevUploadLog.instance,
            builder: (context, _) {
              final log = DevUploadLog.instance;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Upload dev logs', style: textTheme.titleMedium),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Copy all',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: log.dumpText()));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Logs copied')),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: log.clear,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Expanded(
                    child: log.isEmpty
                        ? Center(
                            child: Text('No entries',
                                style: textTheme.bodySmall
                                    ?.copyWith(color: AppColors.textMuted)),
                          )
                        : ListView.builder(
                            itemCount: log.entries.length,
                            itemBuilder: (context, i) {
                              final e = log.entries[i];
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppSpacing.xs),
                                child: SelectableText(
                                  e.line,
                                  style: textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: e.message.contains('FAILED') ||
                                            e.message.contains('threw')
                                        ? AppColors.error
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
