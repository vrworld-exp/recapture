// lib/dev/dev_probe/dev_tools_section.dart
//
// Developer-only "Dev Tools" section for the Projects Hub: an API Health pill
// and an S3 Upload Smoke Test card. Rendered ONLY in non-production flavors
// (see dev_probe_service.dart for the module header + run instructions).
// Self-contained: builds its own Dio instances lazily; never touches
// repositories, notifiers, auth state, Hive, or analytics.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../utils/app_env.dart';
import '../../utils/constants.dart';
import 'bundle_disk_store.dart';
import 'dev_probe_models.dart';
import 'dev_probe_service.dart';
import 'dummy_bundle.dart';

/// The Dev Tools block. In production flavors it renders nothing (and the
/// Projects screen additionally compile-time-gates it out of the tree).
class DevToolsSection extends StatefulWidget {
  const DevToolsSection({
    super.key,
    this.environment = kAppEnvironment,
    this.healthService,
    this.smokeService,
    this.diskStore,
  });

  /// Overridable for widget tests; defaults to the compile-time flavor.
  final AppEnvironment environment;

  /// Test seams — when null, real services against [AppConfig.apiBaseUrl]
  /// are constructed lazily on first use.
  final HealthProbeService? healthService;
  final UploadSmokeService? smokeService;

  /// Test seam for the on-disk bundle store; when null, a real store is
  /// created on IO platforms (never on web — dart:io is unavailable there).
  final BundleDiskStore? diskStore;

  @override
  State<DevToolsSection> createState() => _DevToolsSectionState();
}

class _DevToolsSectionState extends State<DevToolsSection> {
  HealthProbeService? _health;
  UploadSmokeService? _smoke;
  BundleDiskStore? _store;

  bool _healthInFlight = false;
  bool _uploadInFlight = false;
  bool _clearInFlight = false;
  UploadSmokeRun? _run;

  /// Bytes currently held in the dev_probe_bundles folder; null until probed
  /// (or unprobeable — web, tests without the path_provider plugin).
  int? _testFilesBytes;

  /// Step ids the user expanded to inspect the raw response.
  final Set<String> _expandedSteps = <String>{};

  HealthProbeService get _healthService => _health ??= widget.healthService ??
      HealthProbeService(
        dio: Dio(BaseOptions(
          baseUrl: AppConfig.apiBaseUrl,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        )),
      );

  /// Null exactly on web, where dart:io file writes are unavailable and the
  /// smoke test keeps its in-memory bundle.
  BundleDiskStore? get _diskStore =>
      _store ??= widget.diskStore ?? (kIsWeb ? null : BundleDiskStore());

  UploadSmokeService get _smokeService => _smoke ??= widget.smokeService ??
      UploadSmokeService(
        api: Dio(BaseOptions(
          baseUrl: AppConfig.apiBaseUrl,
          connectTimeout: AppConfig.connectTimeout,
          receiveTimeout: AppConfig.receiveTimeout,
        )),
        s3: Dio(),
        store: _diskStore,
      );

  @override
  void initState() {
    super.initState();
    // Leftovers from a previous session should be clearable immediately.
    _refreshTestFilesSize();
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  /// Re-measures the test-files folder. Swallows platform errors (web, widget
  /// tests) — the Clear button simply stays hidden then.
  Future<void> _refreshTestFilesSize() async {
    final store = _diskStore;
    if (store == null) return;
    try {
      final bytes = await store.totalSizeBytes();
      if (mounted) setState(() => _testFilesBytes = bytes);
    } catch (_) {
      // No usable disk (e.g. MissingPluginException in tests) — keep hidden.
    }
  }

  Future<void> _onClearTestFilesTap() async {
    final store = _diskStore;
    if (store == null || _clearInFlight) return;
    setState(() => _clearInFlight = true);
    String message;
    try {
      await store.clear();
      message = 'Test files deleted.';
    } catch (e) {
      message = 'Could not delete test files: $e';
    } finally {
      if (mounted) setState(() => _clearInFlight = false);
    }
    await _refreshTestFilesSize();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onHealthTap() async {
    if (_healthInFlight) return;
    setState(() => _healthInFlight = true);
    HealthCheckResult result;
    try {
      result = await _healthService.check();
    } finally {
      // Clear BEFORE the sheet opens — the pill must not keep spinning under
      // the modal while it waits for dismissal.
      if (mounted) setState(() => _healthInFlight = false);
    }
    if (!mounted) return;
    await _showHealthSheet(result);
  }

  Future<void> _onUploadTap() async {
    if (_uploadInFlight) return;
    setState(() {
      _uploadInFlight = true;
      _expandedSteps.clear();
      _run = null;
    });
    try {
      // The service mutates one run object and pings us after every change.
      final run = await _smokeService.run(
        onUpdate: (r) {
          if (mounted) setState(() => _run = r);
        },
      );
      if (mounted) setState(() => _run = run);
    } finally {
      if (mounted) setState(() => _uploadInFlight = false);
    }
    // A run may have written a fresh bundle folder — re-measure for the
    // Clear button.
    await _refreshTestFilesSize();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.environment.isProduction) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: AppSpacing.sm),
          Align(alignment: Alignment.centerLeft, child: _healthPill()),
          const SizedBox(height: AppSpacing.sm),
          _uploadCard(),
          if ((_testFilesBytes ?? 0) > 0)
            Align(
              alignment: Alignment.centerRight,
              child: _clearTestFilesButton(),
            ),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Text(
          'DEV TOOLS',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.textMuted,
                letterSpacing: 2,
              ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Container(
            height: 0.5,
            color: AppColors.textMuted.withValues(alpha: 0.3),
          ),
        ),
      ],
    );
  }

  /// Compact outlined pill — small and quiet, success-tinted border.
  Widget _healthPill() {
    return Semantics(
      button: true,
      label: 'Check API health',
      child: InkWell(
        onTap: _onHealthTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs + 2),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: AppColors.success.withValues(alpha: 0.55),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_healthInFlight)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.success,
                  ),
                )
              else
                const Icon(Icons.monitor_heart_outlined,
                    size: 16, color: AppColors.success),
              const SizedBox(width: AppSpacing.xs + 2),
              Text(
                'API Health',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Full-width elevated card with a gradient icon chip — visually a
  /// different species from the pill.
  Widget _uploadCard() {
    final run = _run;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: AppColors.disabled.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _uploadInFlight ? null : _onUploadTap,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: const Icon(Icons.cloud_upload,
                            color: AppColors.textPrimary, size: 22),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'S3 Upload Smoke Test',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(color: AppColors.textPrimary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$kSmokeExpectedFilesCount-file dummy bundle → '
                              'backend → AWS',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: AppColors.textMuted),
                            ),
                          ],
                        ),
                      ),
                      if (_uploadInFlight)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                  if (run != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _progressBar(run),
                    const SizedBox(height: AppSpacing.md),
                    ...run.steps.map(_stepRow),
                    if (run.elapsed != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _summaryLine(run),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Quiet text button under the card — deletes the whole dev_probe_bundles
  /// folder (every run's files) and disappears once it's empty.
  Widget _clearTestFilesButton() {
    final kb = (_testFilesBytes ?? 0) / 1024;
    final size = kb >= 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '${kb.toStringAsFixed(0)} KB';
    return TextButton.icon(
      onPressed: _clearInFlight ? null : _onClearTestFilesTap,
      icon: _clearInFlight
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textMuted,
              ),
            )
          : const Icon(Icons.delete_outline,
              size: 16, color: AppColors.textMuted),
      label: Text(
        'Clear test files ($size)',
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: AppColors.textMuted),
      ),
    );
  }

  Widget _progressBar(UploadSmokeRun run) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: LinearProgressIndicator(
        value: run.totalFiles == 0 ? 0 : run.filesCompleted / run.totalFiles,
        minHeight: 6,
        backgroundColor: AppColors.surface2,
        color: run.failed ? AppColors.error : AppColors.success,
      ),
    );
  }

  Widget _stepRow(ProbeStep step) {
    final expanded = _expandedSteps.contains(step.id);
    final hasDetail = step.detail != null && step.detail!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasDetail
              ? () => setState(() => expanded
                  ? _expandedSteps.remove(step.id)
                  : _expandedSteps.add(step.id))
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                _stepIcon(step.state),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    step.title,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: step.state == ProbeStepState.failure
                              ? AppColors.error
                              : AppColors.textSecondary,
                        ),
                  ),
                ),
                if (hasDetail)
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
              ],
            ),
          ),
        ),
        if (expanded && hasDetail) _detailBlock(step.detail!),
      ],
    );
  }

  Widget _stepIcon(ProbeStepState state) {
    switch (state) {
      case ProbeStepState.pending:
        return const Icon(Icons.circle_outlined,
            size: 14, color: AppColors.textMuted);
      case ProbeStepState.running:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.warning,
          ),
        );
      case ProbeStepState.success:
        return const Icon(Icons.check_circle,
            size: 14, color: AppColors.success);
      case ProbeStepState.failure:
        return const Icon(Icons.cancel, size: 14, color: AppColors.error);
    }
  }

  Widget _detailBlock(String detail) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(
          left: AppSpacing.xl, bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          detail,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _summaryLine(UploadSmokeRun run) {
    final seconds = (run.elapsed!.inMilliseconds / 1000).toStringAsFixed(1);
    final kb = (run.totalBytes / 1024).toStringAsFixed(1);
    final text = run.succeeded
        ? '✓ ${run.filesCompleted}/${run.totalFiles} files · $kb KB · ${seconds}s'
        : '✗ Stopped after ${run.filesCompleted}/${run.totalFiles} files · ${seconds}s';
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: run.succeeded ? AppColors.success : AppColors.error,
          ),
    );
  }

  // ── Health result sheet ───────────────────────────────────────────────────

  Future<void> _showHealthSheet(HealthCheckResult result) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      barrierColor: AppColors.scrim,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => _HealthResultSheet(result: result),
    );
  }
}

class _HealthResultSheet extends StatelessWidget {
  const _HealthResultSheet({required this.result});

  final HealthCheckResult result;

  @override
  Widget build(BuildContext context) {
    final statusColor = result.ok &&
            result.statusCode != null &&
            result.statusCode! >= 200 &&
            result.statusCode! < 300
        ? AppColors.success
        : AppColors.error;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'GET /health',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: AppColors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    result.ok ? 'HTTP ${result.statusCode}' : 'UNREACHABLE',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: statusColor),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  '${result.latencyMs} ms',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (result.ok)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    result.body ?? '',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              Text(
                'Backend unreachable at ${result.baseUrl}\n'
                '${result.errorType}: ${result.errorMessage ?? ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.error),
              ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}
