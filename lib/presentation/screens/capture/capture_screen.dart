// lib/presentation/screens/capture/capture_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/analytics/capture_analytics.dart';
import '../../../application/capture/analytics/capture_level_events.dart';
import '../../../application/capture/analytics/capture_level_session.dart';
import '../../../application/capture/analytics/capture_trigger_analytics.dart';
import '../../../application/capture/auto_capture_controller.dart';
import '../../../application/capture/capture_flow_variant_provider.dart';
import '../../../application/capture/capture_lock.dart';
import '../../../application/capture/current_tilt_provider.dart';
import '../../../application/capture/ledger/captured_photo_record.dart';
import '../../../application/capture/ledger/level_capture_ledger.dart';
import '../../../application/capture/ledger/level_capture_ledger_registry_provider.dart';
import '../../../application/capture/pitch_band_resolver.dart';
import '../../../application/capture/ring_progress_provider.dart';
import '../../../application/capture/segment_coverage_provider.dart';
import '../../../application/capture/session/capture_session_codec.dart';
import '../../../application/capture/session/capture_session_store.dart';
import '../../../application/capture/stability_provider.dart';
import '../../../application/config/config_notifier.dart';
import '../../../domain/capture/level_completion.dart';
import '../../../data/local/active_session_box.dart';
import '../../../data/local/auto_capture_box.dart';
import '../../../data/local/capture_settings_box.dart';
import '../../../domain/entities/auto_capture_state.dart';
import '../../../domain/entities/capture_config.dart';
import '../../../domain/entities/capture_evaluation.dart';
import '../../../domain/entities/capture_instruction.dart';
import '../../../domain/entities/capture_pitch_guide.dart';
import '../../../domain/entities/capture_progress.dart';
import '../../../domain/entities/capture_readiness.dart';
import '../../../domain/entities/capture_settings.dart';
import '../../../domain/entities/capture_thumbnail.dart';
import '../../../domain/entities/capture_top_bar_state.dart';
import '../../../domain/entities/save_exit_decision.dart';
import '../../../domain/entities/direction_hint.dart';
import '../../../domain/entities/permission_item.dart';
import '../../../domain/entities/retake_request.dart';
import '../../../domain/entities/ring_coverage.dart';
import '../../../application/capture/retake_session_provider.dart';
import '../../../platform/camera/camera_preview_controller.dart';
import '../../../platform/camera/camera_preview_view.dart';
import '../../../platform/camera/preview_geometry.dart';
import '../../../platform/method_channels.dart';
import '../../../platform/permissions_service.dart';
import '../../../utils/analytics.dart';
import '../../widgets/auto_capture_indicator.dart';
import '../../widgets/capture_overlay_layer.dart';
import '../../widgets/capture_top_bar.dart';
import '../../widgets/direction_arrow_overlay.dart';
import '../../widgets/instruction_banner.dart';
import '../../widgets/level_a_help_sheet.dart';
import '../../widgets/level_a_settings_sheet.dart';
import '../../widgets/placement_box_overlay.dart';
import '../../widgets/post_shot_toast.dart';
import '../../widgets/progress_meter.dart';
import '../../widgets/roll_warning_overlay.dart';
import '../../widgets/save_exit_modal.dart';
import '../../widgets/ring_coverage_map.dart';
import '../../widgets/shutter_button.dart';
import '../../widgets/stability_indicator_overlay.dart';
import '../../widgets/thumbnail_strip.dart';
import '../../widgets/tilt_meter_overlay.dart';
import 'capture_instructions.dart';

// Re-export the per-level instruction cycles so existing call sites (the router)
// and tests that import them from this file keep resolving unchanged after the
// constants were extracted into capture_instructions.dart.
export 'capture_instructions.dart'
    show
        kDefaultCaptureInstructions,
        kLevelBCaptureInstructions,
        kLevelCCaptureInstructions;

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.nextRoute,
    this.instructions = kDefaultCaptureInstructions,
    this.retakeRequest,
    this.permissionsService = const PermissionsService(),
    this.sessionBox,
    this.autoCaptureStore,
    this.captureSettingsStore,
    this.sessionStore,
  });

  final String levelLabel;
  final String levelName;
  final String nextRoute;

  /// The level-tuned instruction cycle shown in the HUD pill. Defaults to
  /// [kDefaultCaptureInstructions] (Level A's copy), so a level that passes
  /// nothing renders identically to today. An empty list falls back to the
  /// default at render time (never an empty/crashing cycle) — see
  /// [_CaptureScreenState._instructions].
  final List<String> instructions;

  /// When non-null, the screen enters RETAKE mode for [RetakeRequest.ringIndex]:
  /// it forces that segment as the active target (overriding normal next-
  /// uncaptured selection), highlights it in the ring map, and on an accepted
  /// shot completes the retake (returning to Review or resuming, per the
  /// request). An out-of-range index falls back to normal targeting — see
  /// [_CaptureScreenState._primeRetake]. Routed in via GoRouter `extra`.
  final RetakeRequest? retakeRequest;

  /// Permission gateway, used to RE-CHECK camera on resume (it is granted
  /// upstream by the gate). Injectable so tests can drive a revoked status.
  final PermissionsService permissionsService;

  /// Source of the active project id for analytics. Null → the real
  /// [ActiveSessionBox]; injectable for tests. Read best-effort (never fatal).
  final ActiveSessionBox? sessionBox;

  /// Persists the auto-capture ON/OFF preference. Null → the real
  /// [AutoCaptureBox]; injectable for tests. Read/written best-effort.
  final AutoCaptureStore? autoCaptureStore;

  /// Persists save-to-gallery + quality (the non-auto-capture settings). Null →
  /// the real [CaptureSettingsBox]; injectable for tests. Best-effort.
  final CaptureSettingsStore? captureSettingsStore;

  /// Persists the resumable capture-session snapshot (filled segments + ledger)
  /// for Save & Exit → Resume. Null → the real [CaptureSessionStore]; injectable
  /// for tests. Every access is guarded, so an unavailable Hive host degrades to
  /// "no resume" rather than crashing.
  final CaptureSessionStore? sessionStore;

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _captureCount = 0;
  bool _showFlash = false;
  int _instructionIndex = 0;
  Timer? _instructionTimer;
  late final AnimationController _flashController;

  /// Auto-capture mode. Defaults ON (smoother guided experience); corrected from
  /// the persisted preference on mount. The FIRE loop is
  /// [_autoCaptureController]; this flag (plus [_autoCaptureSuspended]) gates it.
  AutoCaptureState _autoCapture = const AutoCaptureState(mode: AutoCaptureMode.on);

  /// Preference gateway (injectable). Resolved once.
  late final AutoCaptureStore _autoCaptureStore =
      widget.autoCaptureStore ?? AutoCaptureBox();

  /// Save-to-gallery + quality persistence (injectable). Auto-capture stays in
  /// [_autoCaptureStore] so the pill and Settings sheet share one source.
  late final CaptureSettingsStore _captureSettingsStore =
      widget.captureSettingsStore ?? CaptureSettingsBox();

  /// Save-to-gallery preference (default OFF). Persisted via [_captureSettingsStore].
  bool _saveToGallery = false;

  /// Quality mode (default Standard). Persisted via [_captureSettingsStore].
  QualityMode _quality = QualityMode.standard;

  /// Single live projection of the capture settings the Settings sheet is driven
  /// by. Composed from the auto-capture source + [_saveToGallery]/[_quality], so
  /// auto-capture never diverges from the pill. Reverts (e.g. denied gallery
  /// permission) push back here and the open sheet reflects them.
  late final ValueNotifier<CaptureSettings> _settings =
      ValueNotifier<CaptureSettings>(_composeSettings());

  /// Most recent captures for the thumbnail strip (newest-first, capped). This
  /// is a display slice only — the authoritative capture set lives elsewhere.
  List<CaptureThumbnail> _recentThumbnails = const [];
  static const int _maxThumbnails = 5;

  /// The latest capture's evaluation, fed to the post-shot toast (null = hidden).
  /// The real verdict comes from a (separate) capture-evaluation task; until then
  /// every real frame is treated as accepted — see [_performCapture].
  CaptureEvaluation? _lastEvaluation;

  /// True while a blocking surface (e.g. the Help sheet) is open: auto-capture is
  /// suspended so the fire loop will not arm/shoot behind it. Distinct from the
  /// persisted ON/OFF preference — this is transient and never saved.
  bool _autoCaptureSuspended = false;

  /// User-facing play/pause gate over the automatic capture progression.
  /// Starts TRUE (paused): entering the screen never begins capturing on its
  /// own — the user starts it with the play button in the bottom bar and can
  /// pause/resume at any time. Gates ONLY the auto-capture fire loop; the
  /// manual shutter is an explicit tap and stays live, and preview/sensors/HUD
  /// all keep running so the user can frame while paused. Transient, never
  /// persisted (every entry starts paused by design).
  bool _capturePaused = true;

  /// Single in-flight guard shared by the manual shutter path and the
  /// auto-capture loop, so the two can never run overlapping captures against
  /// the one native capture resource.
  final CaptureLock _captureLock = CaptureLock();

  /// The frame produced by the in-flight auto fire, handed from
  /// [_autoCaptureFrame] to [_onAutoCaptureFilled] (the controller reports only
  /// the segment index, not the frame).
  CapturedFrame? _autoFrame;

  /// The auto-capture FIRE loop: re-evaluates the pure trigger conjunction
  /// (in band + stable + segment unfilled + cooldown) on every smoothed-tilt
  /// tick — see the [currentTiltProvider] listener in [initState] — and fires a
  /// single native capture when it holds. It owns cooldown/in-flight state; the
  /// screen owns enablement ([_autoCapture], [_autoCaptureSuspended], retake,
  /// completion, preview running).
  late final AutoCaptureController _autoCaptureController =
      AutoCaptureController(
    capture: _autoCaptureFrame,
    onFilled: _onAutoCaptureFilled,
    lock: _captureLock,
  );

  /// Drives the native back-camera preview (CAMERA assumed granted by the P2
  /// gate). Released on dispose; stopped on background and rebound on resume.
  late final CameraPreviewController _cameraController;

  /// Triggers a native single still on the SAME bound session as the preview
  /// (CameraX ImageCapture / AVCapturePhotoOutput). Degrades gracefully: a
  /// missing/unbound session or a busy capturer resolves to null, never throws.
  final CaptureChannel _captureChannel = CaptureChannel();

  /// `level_a_camera_opened` is a once-per-screen reach metric.
  bool _openedLogged = false;

  /// De-dupes `level_a_camera_error`: only emit when the error code changes.
  String? _lastErrorCodeLogged;

  /// Guards against firing navigation to the permissions gate more than once.
  bool _routingToGate = false;

  /// Active project id for analytics; resolved best-effort on mount.
  String? _projectId;

  /// The active retake (null = normal guided capture). Set on mount from
  /// [CaptureScreen.retakeRequest] once its index is validated against the live
  /// segment count; drives the post-retake return + the "don't advance the ring"
  /// rule. The HUD highlight is driven separately by [retakeSessionProvider].
  RetakeRequest? _retake;

  /// Guards `capture_level_retake` to a single emission per entry.
  bool _retakeStartedLogged = false;

  /// Guards `capture_level_started` to a single emission per capture session
  /// (this State instance = one entry; a rebuild won't refire, a fresh entry —
  /// including resuming a draft — starts a new session and refires).
  bool _levelStartedLogged = false;

  /// This level as the canonical analytics enum (from the screen's level label).
  CaptureLevel get _captureLevel => captureLevelFromLabel(widget.levelLabel);

  /// The PitchBand.id keying this level's ledger + persisted session AND its
  /// pitch band — the single source [pitchBandIdForLevel] (Level A Eye Ring =
  /// 'mid', B Top Ring = 'high', C Bottom Ring = 'low'). The same id drives the
  /// shutter pitch gate and the tilt indicator, so guidance and enforcement can
  /// never target different bands.
  String get _levelLedgerId => pitchBandIdForLevel(_captureLevel);

  /// The config band id this level's pitch gate + tilt indicator target (alias of
  /// [_levelLedgerId] for read-clarity at the HUD call sites).
  String get _levelBandId => _levelLedgerId;

  /// THIS level's effective ring segment count — config × flow variant × this
  /// level's band, through the single [effectiveSegmentsFor] resolver (the same
  /// N the progression/machine layers and the live HUD providers use). Computed
  /// directly (not via the active-band provider) so it is correct even before
  /// [_activateLevelRing] stamps the active band.
  int _levelSegmentCount() => effectiveSegmentsFor(
        ref.read(captureConfigProvider),
        ref.read(captureFlowVariantProvider),
        _levelBandId,
      );

  /// Whether a saved draft was restored into the live coverage (guards
  /// [_activateLevelRing]'s fresh-ring reset against clobbering a resume that
  /// completed first — the two race on entry and either order must win the same).
  bool _resumedFromDraft = false;

  /// Ring-entry activation of the level-agnostic HUD state: stamps THIS level's
  /// band as the active ring (sizing the live yaw→segment + fill-state providers
  /// to this ring's N — previously they were pinned to the Eye Ring's count for
  /// every level) and, on a fresh guided entry, reshapes + clears the coverage
  /// so a prior level's fills can never leak into this ring. A RETAKE re-entry
  /// keeps the in-progress ring untouched; a completed resume keeps its
  /// restored coverage.
  void _activateLevelRing() {
    ref.read(activeCaptureBandIdProvider.notifier).set(_levelBandId);
    if (widget.retakeRequest != null || _resumedFromDraft) return;
    final coverage = ref.read(segmentCoverageProvider.notifier);
    coverage.reconfigure(segmentCount: _levelSegmentCount());
    coverage.reset();
  }

  /// This level's EFFECTIVE pitch band, resolved ONCE at level entry (initState)
  /// via [resolvedPitchBandProvider] (override → remote/cache → bundled default)
  /// and held STABLE for the whole capture pass — a mid-pass remote/override
  /// change never shifts the target window under the user (it applies next entry).
  /// Drives both the shutter pitch gate and the tilt indicator, so guidance and
  /// enforcement share one band.
  late final PitchBand _resolvedBand;

  /// This level's capture ledger (accepted/warned/rejected), from the root-scoped
  /// registry — a single instance per level across the app session.
  LevelCaptureLedger get _ledger =>
      ref.read(levelCaptureLedgerRegistryProvider).ledgerFor(_levelLedgerId);

  /// Resumable-session persistence (injectable; defaults to the real store).
  late final CaptureSessionStore _sessionStore =
      widget.sessionStore ?? CaptureSessionStore();

  /// Guards the coverage→completion navigation to a single fire per entry (so a
  /// re-capture of an already-filled segment never re-navigates).
  bool _levelCompleteNavigated = false;

  /// The active instruction cycle for this level — the widget's tuned copy, or
  /// [kDefaultCaptureInstructions] when none/empty was supplied (so the cycle is
  /// never empty: `% length` and `[index]` below stay safe).
  List<String> get _instructions => widget.instructions.isNotEmpty
      ? widget.instructions
      : kDefaultCaptureInstructions;

  @override
  void initState() {
    super.initState();
    // Resolve this level's pitch band once, at ring/phase entry, and hold it for
    // the pass (override → remote/cache → bundled default).
    _resolvedBand = ref.read(resolvedPitchBandProvider(_levelBandId));
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _cameraController = CameraPreviewController();
    _cameraController.addListener(_onCameraStateChanged);
    WidgetsBinding.instance.addObserver(this);
    _resolveProjectId();
    _loadAutoCapturePref();
    _loadCaptureSettings();
    // Drive the auto-capture loop from the shared orientation stream: every
    // smoothed-tilt tick re-evaluates the trigger conjunction. listenManual
    // (not watch) — a sensor tick must evaluate, never rebuild the screen. The
    // subscription is closed automatically when this State is disposed.
    ref.listenManual<AsyncValue<TiltSample>>(currentTiltProvider,
        (previous, next) {
      final sample = next.asData?.value;
      if (sample != null) _onOrientationTick(sample);
    });
    // Start after the first frame so the engine texture registry is ready.
    // Priming the retake target is deferred here too: writing to a provider in
    // initState would land mid-build (and reading config is cheap to defer one
    // frame).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activateLevelRing();
      _resetRingYawBaseline();
      _primeRetake();
      _logCaptureStartedIfNeeded();
      _cameraController.start();
    });
    _instructionTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      setState(() {
        _instructionIndex = (_instructionIndex + 1) % _instructions.length;
      });
    });
  }

  /// Best-effort read of the active project id for analytics. Never fatal — a
  /// missing/corrupt session (or an un-init Hive test host) leaves it null.
  Future<void> _resolveProjectId() async {
    try {
      final session = await (widget.sessionBox ?? ActiveSessionBox()).read();
      if (!mounted) return;
      _projectId = session?.projectId;
    } catch (_) {
      _projectId = null;
    }
    // Restore the project's persisted flow variant BEFORE the draft resume —
    // the draft's segment-count validation (and this ring's N) depend on it.
    // Best-effort: an unavailable store keeps the in-memory variant.
    final projectId = _projectId;
    if (projectId != null) {
      try {
        await ref
            .read(captureFlowVariantProvider.notifier)
            .loadFor(projectId);
      } catch (_) {/* keep the in-memory variant */}
      if (!mounted) return;
    }
    // Once the project context is known, restore any saved draft for this level.
    await _tryResume();
  }

  /// Best-effort RESUME of a saved Level A draft into the live state: loads the
  /// snapshot for (project, level) and installs the exact [SegmentCoverage] +
  /// ledger, so the ring map / progress meter / target pick up precisely where the
  /// user left off. A retake entry never resumes (it targets one segment). Absent,
  /// corrupt, or a ring-shape (N) change → start fresh (never a crash). Mirrors the
  /// contract pinned by test/capture/session/save_exit_resume_test.dart.
  Future<void> _tryResume() async {
    final projectId = _projectId;
    if (projectId == null || _retake != null) return;
    try {
      final snap = await _sessionStore.load(projectId, _levelLedgerId);
      if (snap == null || !mounted) return;
      final n = _levelSegmentCount();
      if (snap.segmentCount != n) return; // ring density changed → fresh start
      _resumedFromDraft = true;
      final coverage = CaptureSessionCodec.restoreCoverage(snap);
      ref.read(segmentCoverageProvider.notifier).restore(coverage);
      CaptureSessionCodec.restoreLedger(snap, _ledger);
      setState(() => _captureCount = coverage.filledCount);
      _maybeAutoComplete();
    } catch (_) {
      // Corrupt / unavailable persistence → leave the fresh session in place.
    }
  }

  /// Ring-begin reset of the per-ring yaw reference. This is the SINGLE,
  /// level-agnostic place the reset fires — the capture screen is shared by Levels
  /// A/B/C, so every ring re-establishes its own `yawStart` from the heading the
  /// user is facing when that ring begins (Level C is measured from Level C's
  /// start, never Level B's stale baseline).
  ///
  /// Skipped on a RETAKE re-entry: a retake must keep the original ring reference
  /// so its frames stay aligned with the already-captured ones (it does not begin
  /// a new ring). The actual baseline value is then established by the first valid
  /// yaw sample — an unset baseline gates downstream segment/progress until then.
  void _resetRingYawBaseline() {
    if (widget.retakeRequest != null) return; // retake keeps the ring reference
    ref.read(ringYawBaselineProvider.notifier).reset();
  }

  /// Enters retake mode from the route arg, or guarantees normal targeting.
  ///
  /// Validates the requested [RetakeRequest.ringIndex] against the live segment
  /// count: a valid index forces that segment as the active target (highlighted
  /// via [retakeSessionProvider]) and emits the canonical `capture_level_retake`;
  /// a null/out-of-range request CLEARS any stale forced target so this entry
  /// starts with normal next-uncaptured targeting (no crash, no retake mode).
  void _primeRetake() {
    final request = widget.retakeRequest;
    final segments = _levelSegmentCount();
    final notifier = ref.read(retakeSessionProvider.notifier);

    if (request == null || !request.isValidFor(segments)) {
      _retake = null;
      notifier.clear(); // defensive: never inherit a prior entry's forced target
      return;
    }

    _retake = request;
    notifier.begin(request);
    if (!_retakeStartedLogged) {
      _retakeStartedLogged = true;
      // A retake re-entry LINKS to the in-progress session (ensure, not start).
      final session = ref.read(captureLevelSessionProvider.notifier).ensure(
            level: _captureLevel,
            projectId: _projectId ?? '',
          );
      CaptureAnalytics.log(CaptureLevelRetake(
        level: _captureLevel,
        projectId: session.projectId,
        sessionId: session.sessionId,
        ringIndex: request.ringIndex,
        replacingExisting: !request.isFillingMissing,
        returnMode: request.returnMode,
        deviceType: _deviceType,
      ));
    }
  }

  /// Fires `capture_level_started` ONCE per capture session — but only for a fresh
  /// guided entry, not a retake re-entry (which emits `capture_level_retake`
  /// instead, so the funnel never double-counts a retake as a new start). Starts
  /// the shared analytics session so the completion screen can stitch the funnel
  /// and report `duration_seconds`. Best-effort fields: `target_segments` falls
  /// back to the bundled-default N, `sensor_supported` reflects what is known at
  /// first frame (false while sensors are still warming up / unavailable).
  void _logCaptureStartedIfNeeded() {
    if (_retake != null || _levelStartedLogged) return;
    _levelStartedLogged = true;

    final session = ref.read(captureLevelSessionProvider.notifier).start(
          level: _captureLevel,
          projectId: _projectId ?? '',
        );
    CaptureAnalytics.log(CaptureLevelStarted(
      level: _captureLevel,
      projectId: session.projectId,
      sessionId: session.sessionId,
      captureMode: _autoCapture.isOn ? 'guided' : 'manual',
      targetSegments: _levelSegmentCount(),
      sensorSupported: _sensorSupportedNow(),
      deviceType: _deviceType,
    ));
  }

  /// Best-effort read of whether BOTH IMU-derived signals are usable right now
  /// (mirrors the shutter's gate). False while sensors are warming up.
  bool _sensorSupportedNow() {
    final tilt = ref.read(currentTiltProvider).asData?.value;
    final stability = ref.read(stabilityProvider).asData?.value;
    return (tilt?.sensorSupported ?? false) &&
        (stability?.sensorSupported ?? false);
  }

  /// Best-effort read of the persisted auto-capture preference (default ON when
  /// none is stored / persistence is unavailable). Corrects [_autoCapture] only
  /// when it differs, so there is no needless rebuild.
  Future<void> _loadAutoCapturePref() async {
    final enabled = await _autoCaptureStore.getEnabled() ?? true;
    if (!mounted || enabled == _autoCapture.isOn) return;
    setState(() {
      _autoCapture = AutoCaptureState(
        mode: enabled ? AutoCaptureMode.on : AutoCaptureMode.off,
      );
    });
    _syncSettings();
  }

  /// Best-effort load of the save-to-gallery + quality preferences (defaults:
  /// OFF / Standard). Never fatal — a missing record or unavailable Hive host
  /// leaves the defaults in place.
  Future<void> _loadCaptureSettings() async {
    final save = await _captureSettingsStore.getSaveToGallery();
    final quality = await _captureSettingsStore.getQuality();
    if (!mounted) return;
    setState(() {
      _saveToGallery = save ?? false;
      _quality = quality ?? QualityMode.standard;
    });
    _syncSettings();
  }

  /// The current settings projection (auto-capture from its own source).
  CaptureSettings _composeSettings() => CaptureSettings(
        autoCapture: _autoCapture.isOn,
        saveToGallery: _saveToGallery,
        quality: _quality,
      );

  /// Pushes the latest projection into [_settings] so the (possibly open) sheet
  /// reflects it.
  void _syncSettings() => _settings.value = _composeSettings();

  /// Flips the auto-capture mode, persists the new preference (last-write-wins),
  /// and logs the toggle. Armed/countdown are owned by the (separate) auto-capture
  /// loop, so a manual toggle just sets the mode.
  void _toggleAutoCapture() {
    final newOn = !_autoCapture.isOn;
    setState(() {
      _autoCapture = AutoCaptureState(
        mode: newOn ? AutoCaptureMode.on : AutoCaptureMode.off,
      );
    });
    unawaited(_autoCaptureStore.setEnabled(newOn));
    _syncSettings();
    Analytics.logEvent(AnalyticsEvents.autoCaptureToggled, {
      'new_state': newOn ? 'on' : 'off',
      'device_type': _deviceType,
    });
  }

  /// Flips the play/pause capture gate from the bottom-bar icon button.
  void _toggleCapturePaused() {
    setState(() => _capturePaused = !_capturePaused);
  }

  /// Retake intent from the post-shot toast. Dismisses the toast; the real
  /// discard + re-arm for the shot's ring position is a separate capture task.
  // TODO(capture): discard the rejected/flagged frame and re-arm capture for the
  // same ring position once the evaluator + ring-progress resolver land.
  void _onRetake() {
    if (_lastEvaluation == null) return;
    setState(() => _lastEvaluation = null);
  }

  /// A recent-capture thumbnail was tapped. No preview is built here (the parent
  /// could open one later) — just the analytics signal.
  void _onThumbnailTap(CaptureThumbnail thumb) {
    Analytics.logEvent(AnalyticsEvents.thumbnailTapped, {
      'capture_id': thumb.id,
      'device_type': _deviceType,
    });
  }

  /// Emits the camera analytics on state transitions (not on rebuilds):
  /// `opened` once when the preview reaches running, and `error` (de-duped by
  /// code) when the native pipeline reports a fatal error.
  void _onCameraStateChanged() {
    final state = _cameraController.value;
    if (state.status == CameraPreviewStatus.running && !_openedLogged) {
      _openedLogged = true;
      Analytics.logEvent(AnalyticsEvents.levelACameraOpened, {
        'project_id': _projectId,
        'resolution_preset': _resolutionLabel(state),
        'device_type': _deviceType,
      });
    }
    if (state.status == CameraPreviewStatus.error &&
        state.errorCode != _lastErrorCodeLogged) {
      _lastErrorCodeLogged = state.errorCode;
      Analytics.logEvent(AnalyticsEvents.levelACameraError, {
        'reason': _errorReason(state.errorCode, state.errorMessage),
        'device_type': _deviceType,
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _handleResume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _cameraController.stop();
    }
  }

  /// On foreground, RE-CHECK camera permission before rebinding: it can be
  /// revoked while backgrounded. Granted → restart the preview; revoked → emit
  /// an error event and route back to the permissions gate (never crash).
  Future<void> _handleResume() async {
    final status =
        await widget.permissionsService.status(AppPermissionType.camera);
    if (!mounted) return;
    if (status.isGranted) {
      _cameraController.start();
      return;
    }
    if (_routingToGate) return;
    _routingToGate = true;
    Analytics.logEvent(AnalyticsEvents.levelACameraError, {
      'reason': 'permission_revoked',
      'device_type': _deviceType,
    });
    context.go(AppRoutes.permissions);
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Reports the actual preview resolution (the native pipeline has no
  /// ResolutionPreset); falls back to 'unknown' before the size is known.
  String _resolutionLabel(CameraPreviewState state) =>
      state.previewWidth > 0 && state.previewHeight > 0
          ? '${state.previewWidth}x${state.previewHeight}'
          : 'unknown';

  /// Maps a native error code/message to the analytics `reason` taxonomy.
  /// `permission_revoked` is emitted explicitly from [_handleResume], not here.
  String _errorReason(String? code, String? message) {
    final c = (code ?? '').toUpperCase();
    final m = (message ?? '').toUpperCase();
    if (c.contains('NO_CAMERA') ||
        c.contains('NO_DEVICE') ||
        c == 'UNAVAILABLE' ||
        m.contains('NO CAMERA')) {
      return 'no_camera';
    }
    return 'init_failed';
  }

  /// Full "start over" for this level: wipes the live pass (coverage, ledger,
  /// counters, thumbnails, retake target, saved draft) and rebinds the camera
  /// preview, so the user can recapture from step 0 — offered on the camera
  /// error surface next to the plain Retry (which keeps progress).
  Future<void> _restartCapture() async {
    // Wipe the saved draft first so a later resume can't restore the
    // discarded pass. Best-effort: unavailable persistence never blocks the
    // restart.
    final projectId = _projectId;
    if (projectId != null) {
      try {
        await _sessionStore.clear(projectId, _levelLedgerId);
      } catch (_) {}
    }
    if (!mounted) return;
    ref.read(segmentCoverageProvider.notifier).reset();
    _ledger.reset();
    ref.read(ringYawBaselineProvider.notifier).reset();
    ref.read(retakeSessionProvider.notifier).clear();
    _retake = null;
    setState(() {
      _captureCount = 0;
      _lastEvaluation = null;
      _recentThumbnails = const [];
      _levelCompleteNavigated = false;
    });
    await _cameraController.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController.removeListener(_onCameraStateChanged);
    _cameraController.dispose();
    _flashController.dispose();
    _instructionTimer?.cancel();
    _settings.dispose();
    super.dispose();
  }

  /// Capture-initiation analytics for a manual shutter tap. Fires once per
  /// non-blocked tap (the [ShutterButton] only invokes this when it proceeds, and
  /// before [_performCapture] runs), emitting `manual_capture_triggered` with the
  /// live readiness + the session-shared attempt number. `ring_index` is the
  /// retake target when retaking, else null until live ring-progress is wired.
  void _onManualTriggered(CaptureReadiness readiness) {
    final session = ref.read(captureLevelSessionProvider);
    final attempt = ref.read(captureLevelSessionProvider.notifier).nextAttempt();
    CaptureTriggerAnalytics.manual(
      level: _captureLevel,
      projectId: session?.projectId ?? '',
      sessionId: session?.sessionId ?? '',
      attemptNumber: attempt,
      ringIndex: _retake?.ringIndex,
      inBand: readiness.inBand,
      stable: readiness.stable,
      sensorSupported: readiness.sensorSupported,
      placed: readiness.placed,
      deviceType: _deviceType,
    );
  }

  /// The capture itself, handed to the [ShutterButton] as its `onCapture`. The
  /// button owns haptics and its own tap guard; this acquires the SHARED
  /// [_captureLock] (standing down if an auto fire is in flight), performs the
  /// native single still, and advances the HUD on a real frame. A null frame (no
  /// bound session / busy / non-device test host) is a no-op, not an error.
  Future<void> _performCapture() async {
    if (!_captureLock.tryAcquire()) return; // auto fire in flight — stand down
    try {
      final frame = await _captureChannel.captureSingle();
      if (!mounted) return;
      if (frame == null) return;

      // RETAKE mode: a single targeted shot. It must NOT touch the normal frame
      // counter / thumbnail strip / next-route advance — exactly one segment is
      // in focus and the ring must never advance past it.
      if (_retake != null) {
        _handleRetakeCapture(frame);
        return;
      }

      // TODO(capture): replace with the real CaptureEvaluation from the evaluator
      // (sharpness/exposure/coverage). Until it lands every real frame is treated
      // as accepted, and the (noisy) accepted toast is suppressed during
      // auto-capture bursts — the ring map + progress meter already confirm. Once
      // the evaluator exists, warn/reject must always surface.
      final evaluation = _autoCapture.isOn
          ? null
          : CaptureEvaluation(
              captureId: frame.id,
              verdict: CaptureVerdict.accepted,
            );
      // Record the accepted shot against the ring's current segment (the single
      // source of truth the HUD + completion gate read). Gated on a KNOWN live
      // segment: when sensors are unavailable (no yaw → no segment) the shot
      // still advances the counter/strip but cannot fill a segment — coverage
      // never lies.
      _recordAcceptedCapture(frame);
      _advanceHudAfterCapture(frame, evaluation: evaluation);
      // Auto-complete on real ring coverage: the pure gate over the live
      // SegmentCoverage + accepted ledger decides, and we navigate to the
      // completion route exactly once.
      _maybeAutoComplete();
    } finally {
      _captureLock.release();
    }
  }

  /// One auto-capture evaluation per orientation tick. Reads the live stability,
  /// ring segment, and fill state, then hands the conjunction to
  /// [_autoCaptureController] (which self-limits via the cooldown + the shared
  /// in-flight lock). Disabled — without tearing down trigger state — while
  /// auto-capture is OFF, a blocking sheet is up, a retake is targeted (a single
  /// deliberate shot), the level has completed, or the preview is not running.
  /// Skipped entirely before the ring segment is known (no attributable segment
  /// → no truthful fill), mirroring the manual path's coverage rule.
  void _onOrientationTick(TiltSample tilt) {
    if (!tilt.sensorSupported) return;
    final seg =
        ref.read(currentRingSegmentProvider).valueOrNull?.currentSegment;
    if (seg == null) return;
    final stability = ref.read(stabilityProvider).asData?.value;
    final isStable = (stability?.sensorSupported ?? false) &&
        stability!.stability == Stability.stable;
    final coverage = ref.read(segmentCoverageProvider);
    final enabled = _autoCapture.isOn &&
        !_capturePaused &&
        !_autoCaptureSuspended &&
        _retake == null &&
        !_levelCompleteNavigated &&
        _cameraController.value.status == CameraPreviewStatus.running;
    unawaited(_autoCaptureController.evaluate(
      tiltDegrees: tilt.tiltDegrees,
      band: _resolvedBand,
      isStable: isStable,
      currentSegment: seg,
      isCurrentFilled: coverage.filled[seg],
      enabled: enabled,
    ));
  }

  /// The controller's CaptureFn: emits `autocapture_triggered` at initiation
  /// (the auto twin of [_onManualTriggered]) and performs the native single
  /// still. The frame is stashed for [_onAutoCaptureFilled], which the
  /// controller invokes with the fire-time segment when the frame fills.
  Future<CapturedFrame?> _autoCaptureFrame() async {
    _logAutoTriggered();
    final frame = await _captureChannel.captureSingle();
    _autoFrame = frame;
    return frame;
  }

  /// Capture-initiation analytics for an auto fire. At fire time the trigger
  /// conjunction held by definition, so in-band/stable/sensor-supported are all
  /// true.
  void _logAutoTriggered() {
    final session = ref.read(captureLevelSessionProvider);
    final attempt =
        ref.read(captureLevelSessionProvider.notifier).nextAttempt();
    CaptureTriggerAnalytics.auto(
      level: _captureLevel,
      projectId: session?.projectId ?? '',
      sessionId: session?.sessionId ?? '',
      attemptNumber: attempt,
      ringIndex:
          ref.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
      inBand: true,
      stable: true,
      sensorSupported: true,
      deviceType: _deviceType,
    );
  }

  /// The controller's FillFn: records the auto-accepted frame against the
  /// FIRE-TIME [segmentIndex] (snapshotted by the controller, so a mid-capture
  /// segment change can't misattribute the fill) and advances the HUD. The
  /// accepted toast stays suppressed in auto mode (`evaluation: null`) — the
  /// ring map + progress meter already confirm each shot.
  void _onAutoCaptureFilled(int segmentIndex) {
    final frame = _autoFrame;
    _autoFrame = null;
    if (frame == null || !mounted) return;
    _recordAcceptedAt(frame, segmentIndex);
    _advanceHudAfterCapture(frame, evaluation: null);
    _maybeAutoComplete();
  }

  /// Fills the live [SegmentCoverage] + appends a ledger record for an accepted
  /// [frame], keyed on the ring's current segment. No-op when the current segment
  /// is unknown (sensors warming up / unavailable) — so coverage stays truthful.
  void _recordAcceptedCapture(CapturedFrame frame) {
    final seg =
        ref.read(currentRingSegmentProvider).valueOrNull?.currentSegment;
    if (seg == null) return;
    _recordAcceptedAt(frame, seg);
  }

  /// Fills [seg] in the live coverage + appends the ledger record for [frame].
  /// Quality fields are placeholders until the capture-evaluation task lands; the
  /// path + segment + sensor timestamp are real (enough for resume + review).
  void _recordAcceptedAt(CapturedFrame frame, int seg) {
    ref.read(segmentCoverageProvider.notifier).recordCapture(seg);
    final tilt = ref.read(currentTiltProvider).asData?.value;
    final n = ref.read(segmentCoverageProvider).segmentCount;
    _ledger.recordAccepted(CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: frame.path,
      blurScore: 100, // placeholder (accept band) — evaluator not yet wired
      meanLuminance: 128, // placeholder (mid) — evaluator not yet wired
      yawDegrees: seg * (360.0 / n),
      // The record's pitchDegrees field now carries the 0–180° camera tilt
      // (the value the capture was gated on).
      pitchDegrees: tilt?.tiltDegrees ?? 0,
      sensorTimestampNs: frame.timestampNs,
    ));
  }

  /// Advances the capture HUD for an accepted [frame]: increments the counter,
  /// pushes the thumbnail (newest-first, capped so the strip never grows), sets
  /// the post-shot toast [evaluation] (null = suppressed), and flashes the
  /// screen (skipped under reduce-motion). Shared by the manual and auto paths.
  void _advanceHudAfterCapture(CapturedFrame frame,
      {CaptureEvaluation? evaluation}) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final thumb = CaptureThumbnail(
      id: frame.id,
      filePath: frame.path,
      capturedAt: DateTime.now(),
    );
    setState(() {
      _captureCount++;
      _lastEvaluation = evaluation;
      _recentThumbnails =
          [thumb, ..._recentThumbnails].take(_maxThumbnails).toList();
      if (!reduceMotion) _showFlash = true;
    });
    if (!reduceMotion) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) setState(() => _showFlash = false);
      });
    }
  }

  /// Evaluates the Level A completion gate against the live coverage + accepted
  /// count and, when complete, navigates to [CaptureScreen.nextRoute] once.
  /// `minAcceptedCount` is 1: the repo has no Dart count-config field, so coverage
  /// (`CaptureConfig.thresholds.minCoveragePct`) is the effective production gate —
  /// reaching it already implies ≥1 accepted. Retake mode never auto-completes.
  void _maybeAutoComplete() {
    if (_levelCompleteNavigated || _retake != null) return;
    final coverage = ref.read(segmentCoverageProvider);
    final completion = evaluateLevelAFromCoverage(
      coverage,
      acceptedCount: _ledger.accepted.length,
      minAcceptedCount: 1,
      minCoveragePct: ref.read(captureConfigProvider).thresholds.minCoveragePct,
    );
    if (!completion.isComplete) return;
    _levelCompleteNavigated = true;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) context.go(widget.nextRoute);
    });
  }

  /// Completes (or holds) a retake shot for the forced target.
  ///
  /// A REJECTED retake keeps the existing good capture and stays on the same
  /// target (reject discards the NEW shot, never the old one). An ACCEPTED retake
  /// replaces/fills the segment, clears retake mode, and either returns to Review
  /// (single retake) or resumes normal targeting.
  void _handleRetakeCapture(CapturedFrame frame) {
    final request = _retake;
    if (request == null) return;

    // TODO(capture): real verdict from the evaluator (sharpness/exposure). Until
    // it lands a retake frame is treated as accepted, so the flow below always
    // completes. Once the evaluator exists, a REJECT must early-return here
    // (keeping the old capture, surfacing the reject toast, staying on the
    // target) and a WARN must report new_verdict: 'warn'.

    // Fill the FORCED target in the live coverage + ledger so the freed/missing
    // segment becomes covered (the whole point of the retake). The segment is the
    // request's ringIndex — known without sensors, so a retake fills deterministically.
    // TODO(capture): a REPLACE retake should also remove the old [replacingCaptureId]
    // record + its file (CaptureStorage); until that lands the new accept is added
    // and `filled` stays correct (idempotent re-fill of an already-filled segment).
    ref.read(segmentCoverageProvider.notifier).recordCapture(request.ringIndex);
    final n = ref.read(segmentCoverageProvider).segmentCount;
    final tilt = ref.read(currentTiltProvider).asData?.value;
    _ledger.recordAccepted(CapturedPhotoRecord(
      segmentIndex: request.ringIndex,
      framePath: frame.path,
      blurScore: 100, // placeholder — evaluator not yet wired
      meanLuminance: 128, // placeholder — evaluator not yet wired
      yawDegrees: request.ringIndex * (360.0 / n),
      pitchDegrees: tilt?.tiltDegrees ?? 0,
      sensorTimestampNs: frame.timestampNs,
    ));

    Analytics.logEvent(AnalyticsEvents.retakeCompleted, {
      'ring_index': request.ringIndex,
      'new_verdict': 'accepted',
      'device_type': _deviceType,
    });

    _retake = null;
    ref.read(retakeSessionProvider.notifier).clear();

    if (request.returnToReviewAfter) {
      // Single retake → return to the Review grid it was pushed from.
      _returnToReview();
    }
    // Resume mode: stay in capture; the cleared forced target lets normal
    // next-segment targeting resume.
  }

  /// Returns to the Level A Review grid after a single retake (or backing out of
  /// retake mode). Pops when the capture screen was pushed from Review; otherwise
  /// navigates there directly.
  void _returnToReview() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.levelAReview);
    }
  }

  /// Top-bar level code for analytics, e.g. "Level A" → "A". The bar is generic;
  /// the screen owns the level taxonomy.
  String get _levelCode => widget.levelLabel.split(' ').last;

  void _logTopBarAction(String action) {
    Analytics.logEvent(AnalyticsEvents.captureTopbarAction, {
      'action': action,
      'level': _levelCode,
      'device_type': _deviceType,
    });
  }

  /// Back/close intent from the top bar. The bar already debounced the tap; the
  /// screen owns whether to confirm before leaving (the same flow the system
  /// back gesture funnels through).
  void _onTopBarBack() {
    _logTopBarAction('back');
    unawaited(_confirmExit());
  }

  /// Help intent. Opens the quick-tips sheet, suspending auto-capture while it is
  /// up and resuming on dismissal (every dismiss path returns from the await).
  void _onTopBarHelp() {
    _logTopBarAction('help');
    unawaited(_openHelpSheet());
  }

  Future<void> _openHelpSheet() async {
    setState(() => _autoCaptureSuspended = true); // pause around the sheet
    try {
      await showLevelAHelpSheet(context, onReplayIntro: _onReplayIntro);
    } finally {
      if (mounted) setState(() => _autoCaptureSuspended = false); // resume
    }
  }

  /// Replay intro from the Help sheet (the sheet already dismissed itself).
  void _onReplayIntro() {
    if (mounted) context.go(AppRoutes.levelAIntro);
  }

  /// Settings intent. Opens the capture-settings sheet, suspending auto-capture
  /// while it is up and resuming on dismissal (every dismiss path returns).
  void _onTopBarSettings() {
    _logTopBarAction('settings');
    unawaited(_openSettingsSheet());
  }

  Future<void> _openSettingsSheet() async {
    _syncSettings(); // present the latest values, no wrong-state flash
    setState(() => _autoCaptureSuspended = true);
    try {
      await showLevelASettingsSheet(
        context,
        settings: _settings,
        onChanged: _onSettingChanged,
      );
    } finally {
      if (mounted) setState(() => _autoCaptureSuspended = false);
    }
  }

  /// Applies a single changed setting (the sheet emits the analytics; the parent
  /// persists + applies). Auto-capture routes through the SAME store/key as the
  /// pill; save-to-gallery requests permission and reverts if denied.
  void _onSettingChanged(CaptureSettings next) {
    final cur = _settings.value;
    if (next.autoCapture != cur.autoCapture) {
      _applyAutoCaptureSetting(next.autoCapture);
    } else if (next.quality != cur.quality) {
      _applyQualitySetting(next.quality);
    } else if (next.saveToGallery != cur.saveToGallery) {
      unawaited(_applySaveToGallerySetting(next.saveToGallery));
    }
  }

  void _applyAutoCaptureSetting(bool on) {
    setState(() {
      _autoCapture = AutoCaptureState(
        mode: on ? AutoCaptureMode.on : AutoCaptureMode.off,
      );
    });
    unawaited(_autoCaptureStore.setEnabled(on)); // shared pill key
    _syncSettings();
  }

  void _applyQualitySetting(QualityMode quality) {
    setState(() => _quality = quality);
    unawaited(_captureSettingsStore.setQuality(quality));
    _syncSettings();
    // TODO(capture): apply live (reconfigure capture resolution) or on the next
    // capture — the quality→resolution mapping is owned by a separate task.
  }

  /// Save-to-gallery: turning OFF just persists. Turning ON optimistically
  /// reflects ON, requests photo permission, and reverts (the open sheet shows
  /// OFF via [_settings]) if it is denied. Permission lives here, not the sheet.
  Future<void> _applySaveToGallerySetting(bool on) async {
    if (!on) {
      setState(() => _saveToGallery = false);
      unawaited(_captureSettingsStore.setSaveToGallery(false));
      _syncSettings();
      return;
    }
    setState(() => _saveToGallery = true); // optimistic
    _syncSettings();
    final status =
        await widget.permissionsService.request(AppPermissionType.photos);
    if (!mounted) return;
    if (status.isGranted) {
      unawaited(_captureSettingsStore.setSaveToGallery(true));
    } else {
      setState(() => _saveToGallery = false); // revert
      unawaited(_captureSettingsStore.setSaveToGallery(false));
      _syncSettings();
    }
  }

  /// Unsaved progress = at least one capture this session not yet committed as a
  /// draft. Drives both the [PopScope] gate and the top-bar back flow.
  bool get _hasUnsavedProgress => _captureCount > 0;

  /// The single exit flow both the top-bar back AND the system back funnel
  /// through. No progress → leave directly; otherwise confirm via the modal.
  Future<void> _confirmExit() async {
    // Retake mode: backing out makes NO changes (the old capture/segment state is
    // preserved) and returns to Review — not the Save & Exit flow, since a retake
    // has no committed new progress until an accepted shot (which navigates away
    // on its own).
    if (_retake != null) {
      _retake = null;
      ref.read(retakeSessionProvider.notifier).clear();
      _returnToReview();
      return;
    }
    if (!_hasUnsavedProgress) {
      _exitToProjects();
      return;
    }
    final choice = await showSaveExitConfirmation(
      context,
      ctx: SaveExitContext(
        capturedCount: _captureCount,
        hasUnsavedProgress: true,
      ),
    );
    if (!mounted) return;
    _handleExitChoice(choice);
  }

  /// Applies the user's choice. Save persists a resumable snapshot (the exact
  /// filled segments + ledger) so Resume restores it losslessly; Discard clears
  /// any saved draft and the in-memory state; both then navigate out. Persistence
  /// is best-effort and guarded — an unavailable store never blocks the exit.
  void _handleExitChoice(SaveExitChoice choice) {
    switch (choice) {
      case SaveExitChoice.saveExit:
        unawaited(_saveSessionThenExit());
      case SaveExitChoice.discardExit:
        unawaited(_discardSessionThenExit());
      case SaveExitChoice.cancel:
        break; // stay on the capture screen
    }
  }

  /// Persists the current coverage + ledger as a resumable draft, then exits.
  Future<void> _saveSessionThenExit() async {
    await _persistSession();
    if (mounted) _exitToProjects();
  }

  /// Clears any saved draft + the in-memory coverage/ledger, then exits.
  Future<void> _discardSessionThenExit() async {
    final projectId = _projectId;
    if (projectId != null) {
      try {
        await _sessionStore.clear(projectId, _levelLedgerId);
      } catch (_) {/* best-effort */}
    }
    ref.read(segmentCoverageProvider.notifier).reset();
    _ledger.reset();
    if (mounted) _exitToProjects();
  }

  /// Best-effort save of the resumable snapshot. No-op without a project context
  /// (analytics/session not resolved) or when the store is unavailable.
  Future<void> _persistSession() async {
    final projectId = _projectId;
    if (projectId == null) return;
    try {
      await _sessionStore.save(CaptureSessionCodec.capture(
        projectId: projectId,
        levelId: _levelLedgerId,
        coverage: ref.read(segmentCoverageProvider),
        ledger: _ledger,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {/* best-effort — never block the exit */}
  }

  void _exitToProjects() => context.go(AppRoutes.projects);

  /// System/hardware back: when there is unsaved progress the route is blocked
  /// ([PopScope.canPop] false) and this confirms via the SAME flow as the
  /// top-bar back, so both behave identically.
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    unawaited(_confirmExit());
  }

  @override
  Widget build(BuildContext context) {
    // Keep the live yaw→segment position synced into SegmentCoverage so the ring
    // map highlights the correct target. Watching it here keeps the binder (and
    // thus the single shared orientation subscription) alive for the screen's life
    // and auto-disposes on leave. No-op until the first valid yaw / when sensors
    // are unavailable.
    ref.watch(ringPositionBinderProvider);
    return PopScope(
      // Blocked while there is unsaved progress so the system back gesture/button
      // funnels through the same Save & Exit confirmation as the top-bar back.
      canPop: !_hasUnsavedProgress,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        backgroundColor: AppColors.bgPrimary,
      // LayoutBuilder gives the on-screen size; the controller value gives the
      // native frame size/rotation. Together they form the PreviewGeometry the
      // overlay layer hands to every overlay. This rebuilds only on layout or
      // preview-state changes (not per camera frame — the Texture updates
      // independently of the widget tree).
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<CameraPreviewState>(
            valueListenable: _cameraController,
            builder: (context, state, _) {
              final geometry = PreviewGeometry.fromPreviewState(
                previewWidth: state.previewWidth,
                previewHeight: state.previewHeight,
                rotationDegrees: state.rotationDegrees,
                screenSize: constraints.biggest,
                fit: BoxFit.cover,
              );
              return CaptureOverlayLayer(
                geometry: geometry,
                cameraPreview: CameraPreview(
                  controller: _cameraController,
                  placeholder: const _CameraLoading(),
                  errorBuilder: (context, s) => _CameraErrorSurface(
                    message: s.errorMessage,
                    onRetry: _cameraController.start,
                    onRestart: _restartCapture,
                    onBack: () => context.go(AppRoutes.projects),
                  ),
                ),
                overlays: [
                  // Render-only centre-frame guide. Status is idle until a
                  // later detection task supplies placement quality.
                  PlacementBoxOverlay(geometry: geometry),
                  CaptureTopBar(
                    state: CaptureTopBarState(
                      levelLabel: widget.levelLabel,
                      levelSubtitle: widget.levelName,
                    ),
                    onBack: _onTopBarBack,
                    onHelp: _onTopBarHelp,
                    onSettings: _onTopBarSettings,
                  ),
                  // Single authoritative instruction pill. Fed here by the
                  // existing demo cycling; a later priority-resolver task will
                  // map live HUD state into this one CaptureInstruction.
                  InstructionBanner(
                    instruction: CaptureInstruction(
                      id: 'demo_$_instructionIndex',
                      message: _instructions[_instructionIndex],
                    ),
                  ),
                  // Segmented ring coverage (N from the Level A config band).
                  // Filled/target come from a later ring-progress resolver.
                  const _RingCoverageHud(),
                  // Textual progress meter (top-centre) reading the same source
                  // as the ring map so the numbers never disagree.
                  const _ProgressMeterHud(),
                  // Live pitch-vs-band tilt guidance (needle + target band),
                  // targeting THIS level's band (Eye/Top/Bottom Ring) — the gauge
                  // zone + scale auto-tune to it.
                  TiltMeterOverlay(
                    levelBandId: _levelBandId,
                    band: _resolvedBand,
                    level: _captureLevel.code,
                  ),
                  // Live steadiness dot driven by the native stability gate.
                  const StabilityIndicatorOverlay(),
                  // Roll advisory ("Keep the phone level") — Levels B & C only.
                  // Non-blocking and read by nothing in the capture path; it
                  // warns past ±15° roll but never gates frames or completion.
                  if (_captureLevel != CaptureLevel.a)
                    RollWarningOverlay(level: _captureLevel),
                  // Ring-direction arrow. Hidden until a later resolver task maps
                  // yaw + ring progress into a DirectionHint.
                  const DirectionArrowOverlay(hint: DirectionHint.hidden),
                  // Auto-capture ON/OFF pill (top-right, below the top bar).
                  Positioned(
                    top: 0,
                    right: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: 44,
                          right: AppSpacing.lg,
                        ),
                        child: AutoCaptureIndicator(
                          // While suspended (e.g. Help sheet open) the loop is
                          // paused, so it can never be armed.
                          state: _autoCaptureSuspended
                              ? AutoCaptureState(mode: _autoCapture.mode)
                              : _autoCapture,
                          onToggle: _toggleAutoCapture,
                        ),
                      ),
                    ),
                  ),
                  _BottomBar(
                    captureCount: _captureCount,
                    playPause: _PlayPauseButton(
                      paused: _capturePaused,
                      onToggle: _toggleCapturePaused,
                    ),
                    shutter: _ShutterControl(
                      band: _resolvedBand,
                      onCapture: _performCapture,
                      onTriggered: _onManualTriggered,
                    ),
                    thumbnails: ThumbnailStrip(
                      recent: _recentThumbnails,
                      maxVisible: 3,
                      onTapThumbnail: _onThumbnailTap,
                    ),
                  ),
                  // Post-shot quality feedback (single instance, latest-wins).
                  // Sits above the shutter/HUD in its own band.
                  PostShotToast(
                    evaluation: _lastEvaluation,
                    onRetake: _onRetake,
                  ),
                  if (_showFlash)
                    Container(color: Colors.white.withValues(alpha: 0.3)),
                  // Debug-only: visualizes the PreviewGeometry mapping.
                  if (kDebugMode && kShowCaptureDebugReticle)
                    const CaptureDebugReticleOverlay(),
                ],
              );
            },
          );
        },
      ),
      ),
    );
  }
}

/// Branded loading state shown while the preview is being acquired (Deep Black +
/// spinner). Replaces the controller's plain black placeholder.
class _CameraLoading extends StatelessWidget {
  const _CameraLoading();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.bgPrimary,
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.mirageRed,
          ),
        ),
      ),
    );
  }
}

/// Branded camera-error state with retry + back, on Deep Black. Shown when the
/// native pipeline reports a fatal error (init failed, camera in use, no camera).
/// [onRestart] (optional) additionally offers a from-zero restart of the level's
/// capture pass: Retry keeps progress and just rebinds the camera; Start over
/// clears the pass and rebinds.
class _CameraErrorSurface extends StatelessWidget {
  const _CameraErrorSurface({
    required this.onRetry,
    required this.onBack,
    this.onRestart,
    this.message,
  });

  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback? onRestart;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bgPrimary,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off,
                  color: AppColors.textSecondary, size: 44),
              const SizedBox(height: AppSpacing.lg),
              Text(
                message ?? 'Camera unavailable',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: onBack,
                    child: Text(
                      'Back',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  ElevatedButton(
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
              if (onRestart != null) ...[
                const SizedBox(height: AppSpacing.md),
                TextButton.icon(
                  key: const ValueKey('camera_error_restart'),
                  onPressed: onRestart,
                  icon: const Icon(Icons.refresh,
                      size: 18, color: AppColors.textSecondary),
                  label: Text(
                    'Start over (clears this level)',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Assembles [CaptureReadiness] from the tilt + stability providers (the button
/// does not subscribe to sensors itself) and renders the gated [ShutterButton].
/// Guided mode; placement is not gated yet (no detection). Until sensor samples
/// arrive — or if sensors are unavailable — `sensorSupported` is false, so the
/// shutter fails OPEN (never locks the user out).
class _ShutterControl extends ConsumerWidget {
  const _ShutterControl({
    required this.band,
    required this.onCapture,
    this.onTriggered,
  });

  /// The EFFECTIVE pitch band THIS level enforces — resolved once at level entry
  /// (override → remote/cache → bundled default) and held stable for the pass by
  /// the parent. The same band drives the tilt indicator, so guidance and the gate
  /// agree; and a mid-pass config/override change never shifts the gate.
  final PitchBand band;

  final Future<void> Function() onCapture;

  /// Capture-initiation hook (fires once per non-blocked tap) — the parent emits
  /// `manual_capture_triggered` with full context from the readiness.
  final void Function(CaptureReadiness readiness)? onTriggered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tilt = ref.watch(currentTiltProvider).asData?.value;
    final stability = ref.watch(stabilityProvider).asData?.value;

    final tiltSupported = tilt?.sensorSupported ?? false;
    final stabilitySupported = stability?.sensorSupported ?? false;

    return ShutterButton(
      key: const ValueKey('capture_shutter'),
      readiness: CaptureReadiness(
        mode: CaptureMode.guided,
        // Reuse the SHARED pitch-band gate (min inclusive, max exclusive) — the
        // same membership the auto-capture trigger's isInPitchBand uses.
        inBand: tiltSupported &&
            CapturePitchGuide.isInBand(band, tilt!.tiltDegrees),
        stable: stabilitySupported && stability!.stability == Stability.stable,
        // Both sensors must be usable to gate; otherwise fail open.
        sensorSupported: tiltSupported && stabilitySupported,
      ),
      onCapture: onCapture,
      onTriggered: onTriggered,
    );
  }
}

/// Live frame counter (bottom-right of the bottom bar): photos taken this
/// session over the ring's target segment count. The denominator comes from the
/// SAME [segmentCoverageProvider] the ring map + progress meter read, so every
/// HUD readout shares one N. Deliberately DISTINCT from the ring badge's
/// filled/N: a real frame with an unknown segment (sensors warming up) still
/// counts as a photo taken here, but never claims coverage. Replaces the
/// demo-era hardcoded `"${captureCount + 12}/36"` stub, which showed 12/36 with
/// zero captures.
class _CaptureCounter extends ConsumerWidget {
  const _CaptureCounter({required this.captureCount});

  final int captureCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n =
        ref.watch(segmentCoverageProvider.select((c) => c.segmentCount));
    return Text(
      '$captureCount/$n',
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(color: Colors.white),
    );
  }
}

/// Renders the [RingCoverageMap] from the live [segmentCoverageProvider] (filled
/// segments + nearest-missing target), with the retake-forced target overriding
/// when present. Segment count (N) comes from that provider, seeded off the same
/// eye-ring config band the rest of the HUD uses.
class _RingCoverageHud extends ConsumerWidget {
  const _RingCoverageHud();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Live fill state (single source of truth). The map renders the actual filled
    // segments + the nearest-missing target (or, in retake mode, the forced one).
    final coverage = ref.watch(segmentCoverageProvider);
    // In retake mode the forced segment is THE target — it flows through the same
    // RingCoverage.targetIndex the normal next-uncaptured target uses, so the
    // chosen angle is the one highlighted. Out-of-range requests are ignored,
    // falling back to coverage's own nearest-missing target.
    final retake = ref.watch(retakeSessionProvider);
    final forcedTarget = (retake != null && retake.isValidFor(coverage.segmentCount))
        ? retake.ringIndex
        : null;
    return RingCoverageMap(
      coverage: coverage.toRingCoverage(targetIndex: forcedTarget),
    );
  }
}

/// Renders the textual [ProgressMeter] from the SAME source as the ring map —
/// segment count (N) from the config band, accepted/coverage from the shared
/// [RingCoverage] — so the two HUD readouts can never disagree. Empty until the
/// ring-progress resolver supplies filled segments; the completion threshold is
/// CaptureConfig's `minCoveragePct`.
class _ProgressMeterHud extends ConsumerWidget {
  const _ProgressMeterHud();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(captureConfigProvider);
    // Same live source as the ring map → the two readouts can never disagree.
    final coverage = ref.watch(segmentCoverageProvider).toRingCoverage();
    return ProgressMeter(
      progress: CaptureProgress.fromCoverage(
        coverage,
        completeAtPct: config.thresholds.minCoveragePct,
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.captureCount,
    required this.playPause,
    required this.shutter,
    required this.thumbnails,
  });

  /// Photos captured this session (every real frame, whether or not it could
  /// fill a segment) — the numerator of the bottom-right counter.
  final int captureCount;

  /// The play/pause icon control gating the auto-capture progression.
  final Widget playPause;

  /// The gated shutter control (assembles its own readiness from providers).
  final Widget shutter;

  /// The recent-capture thumbnail strip (bottom-left slot).
  final Widget thumbnails;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          height: 100,
          color: AppColors.surface1.withValues(alpha: 0.9),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Recent-capture thumbnail strip (replaces the old static tiles).
              // Flexible so the slot compresses before the bar can overflow on
              // narrow screens now that the play/pause control shares the row.
              Flexible(child: SizedBox(width: 160, child: thumbnails)),
              playPause,
              shutter,
              // Live frame counter (the auto-capture ON/OFF state lives in the
              // top-right AutoCaptureIndicator pill).
              _CaptureCounter(captureCount: captureCount),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icon-only play/pause control for the capture progression (bottom bar, left
/// of the shutter). Shows a play icon while paused — capture waits for the
/// user — and a pause icon while running.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.paused, required this.onToggle});

  final bool paused;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // Paused = the CTA to start capturing, so it wears the red-energy
    // gradient + glow; running = quiet obsidian surface with a gold rim.
    return Semantics(
      button: true,
      label: paused ? 'Start capturing' : 'Pause capturing',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: paused ? AppColors.primaryGradient : null,
          color: paused ? null : AppColors.surface2.withValues(alpha: 0.9),
          border: Border.all(
            color: paused
                ? AppColors.redGlow.withValues(alpha: 0.6)
                : AppColors.royalGold.withValues(alpha: 0.4),
            width: 1.5,
          ),
          boxShadow: paused
              ? [
                  BoxShadow(
                    color: AppColors.redGlow.withValues(alpha: 0.4),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            key: const ValueKey('capture_play_pause'),
            customBorder: const CircleBorder(),
            onTap: onToggle,
            child: Icon(
              paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: AppColors.textPrimary,
              size: 34,
            ),
          ),
        ),
      ),
    );
  }
}
