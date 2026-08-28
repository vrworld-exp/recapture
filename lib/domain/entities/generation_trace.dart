// lib/domain/entities/generation_trace.dart
//
// How a 3D-model generation was DECIDED: the synchronous steps the server ran
// between "someone pressed Generate" and "a job is queued", plus the photo
// selector's counters.
//
// Hand-synced with the backend's GenerationStep / AutoSelectionTrace
// (recapture-api/src/models/types/projectModel.types.ts and
// services/autoPhotoSelectionService.ts) — there is no shared package.
//
// TWO THINGS THIS IS NOT:
//   • it is not progress. These steps are all over in well under a second and
//     arrive already-finished in the POST response; the minutes-long half is
//     [ModelProgress], polled separately. Rendering them as if they were live
//     is the main way this feature looks broken.
//   • it is not owner-facing. It names our S3 keys and our pipeline's internals,
//     so it is shown only behind the staff + debug gate.
//
// EVERY field is nullable or defaulted: records written before the trace existed
// have none at all, and a build must never assume otherwise.

/// One synchronous decision step, in the order the server runs them.
enum GenerationStepName {
  resolveJob,
  loadManifest,
  listObjects,
  selectPhotos,
  guards,
  enqueue,

  /// A step this build does not know (server ahead of the app). Rendered with
  /// its raw name rather than dropped — an unknown step in a failing trace is
  /// exactly the one worth seeing.
  unknown;

  static GenerationStepName parse(Object? raw) => switch (raw.toString()) {
        'RESOLVE_JOB' => GenerationStepName.resolveJob,
        'LOAD_MANIFEST' => GenerationStepName.loadManifest,
        'LIST_OBJECTS' => GenerationStepName.listObjects,
        'SELECT_PHOTOS' => GenerationStepName.selectPhotos,
        'GUARDS' => GenerationStepName.guards,
        'ENQUEUE' => GenerationStepName.enqueue,
        _ => GenerationStepName.unknown,
      };
}

enum GenerationStepStatus {
  ok,
  skipped,
  failed,
  unknown;

  static GenerationStepStatus parse(Object? raw) => switch (raw.toString()) {
        'OK' => GenerationStepStatus.ok,
        'SKIPPED' => GenerationStepStatus.skipped,
        'FAILED' => GenerationStepStatus.failed,
        _ => GenerationStepStatus.unknown,
      };
}

/// One step as the server decided it.
class GenerationStep {
  const GenerationStep({
    required this.name,
    required this.status,
    required this.rawName,
    this.detail,
    this.durationMs,
  });

  final GenerationStepName name;
  final GenerationStepStatus status;

  /// The wire name, kept so an unknown step still has something to show.
  final String rawName;

  /// Staff-safe one-liner — may name keys and counts, never a URL.
  final String? detail;
  final int? durationMs;

  static GenerationStep? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final rawName = (raw['step'] ?? '').toString();
    if (rawName.isEmpty) return null;
    final detail = (raw['detail'] ?? '').toString();
    final duration = raw['durationMs'];
    return GenerationStep(
      name: GenerationStepName.parse(rawName),
      status: GenerationStepStatus.parse(raw['status']),
      rawName: rawName,
      detail: detail.isEmpty ? null : detail,
      durationMs: duration is num ? duration.round() : null,
    );
  }

  static List<GenerationStep> parseList(Object? raw) => [
        if (raw is List)
          for (final s in raw)
            if (GenerationStep.tryParse(s) case final step?) step,
      ];
}

/// One photo the selector picked, and the two facts that picked it.
class ChosenPhoto {
  const ChosenPhoto({required this.key, this.blurScore, this.quadrant});

  final String key;
  final double? blurScore;

  /// Yaw bucket 0–3, or null when the photo could not be placed on the circle.
  final int? quadrant;

  static ChosenPhoto? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = (raw['key'] ?? '').toString();
    if (key.isEmpty) return null;
    final blur = raw['blurScore'];
    final quadrant = raw['quadrant'];
    return ChosenPhoto(
      key: key,
      blurScore: blur is num ? blur.toDouble() : null,
      quadrant: quadrant is num ? quadrant.toInt() : null,
    );
  }
}

/// The photo selector's counters — every candidate accounted for.
///
/// The counters matter more than the outcome. `NO_USABLE_PHOTOS` can mean the
/// manifest paths were unresolvable, the objects were missing from the bucket,
/// or that not one photo carried a sharpness score (the expected answer for any
/// capture recorded before the packer started writing it). Those are three
/// different problems and only [droppedNoBlurScore] and friends tell them apart.
class GenerationSelectionTrace {
  const GenerationSelectionTrace({
    this.ringUsed,
    this.photosInManifest = 0,
    this.poolSize = 0,
    this.droppedUnresolvableKey = 0,
    this.droppedMissingObject = 0,
    this.droppedNoBlurScore = 0,
    this.belowBlurFloor = 0,
    this.warnedExcluded = 0,
    this.minBlurScoreUsed,
    this.segmentCountUsed,
    this.quadrantHistogram = const [0, 0, 0, 0],
    this.unplacedCount = 0,
    this.chosen = const [],
  });

  /// 'EYE' or 'ALL' — which pool the eye-level preference settled on.
  final String? ringUsed;
  final int photosInManifest;
  final int poolSize;
  final int droppedUnresolvableKey;
  final int droppedMissingObject;
  final int droppedNoBlurScore;
  final int belowBlurFloor;
  final int warnedExcluded;
  final double? minBlurScoreUsed;

  /// The ring size read from the capture config; null means the selector fell
  /// back to absolute yaw.
  final int? segmentCountUsed;

  /// Usable photos per yaw quadrant — the spread the decision turned on.
  final List<int> quadrantHistogram;
  final int unplacedCount;
  final List<ChosenPhoto> chosen;

  /// How many of the four quadrants had at least one usable photo.
  int get quadrantsFilled => quadrantHistogram.where((n) => n > 0).length;

  static GenerationSelectionTrace? tryParse(Object? raw) {
    if (raw is! Map) return null;
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return GenerationSelectionTrace(
      ringUsed: raw['ringUsed']?.toString(),
      photosInManifest: asInt(raw['photosInManifest']),
      poolSize: asInt(raw['poolSize']),
      droppedUnresolvableKey: asInt(raw['droppedUnresolvableKey']),
      droppedMissingObject: asInt(raw['droppedMissingObject']),
      droppedNoBlurScore: asInt(raw['droppedNoBlurScore']),
      belowBlurFloor: asInt(raw['belowBlurFloor']),
      warnedExcluded: asInt(raw['warnedExcluded']),
      minBlurScoreUsed:
          raw['minBlurScoreUsed'] is num ? (raw['minBlurScoreUsed'] as num).toDouble() : null,
      segmentCountUsed:
          raw['segmentCountUsed'] is num ? (raw['segmentCountUsed'] as num).toInt() : null,
      quadrantHistogram: [
        if (raw['quadrantHistogram'] case final List h)
          for (final n in h) asInt(n)
        else
          ...const [0, 0, 0, 0],
      ],
      unplacedCount: asInt(raw['unplacedCount']),
      chosen: [
        if (raw['chosen'] case final List c)
          for (final p in c)
            if (ChosenPhoto.tryParse(p) case final photo?) photo,
      ],
    );
  }
}

/// The persisted trace carried on a staff model record (`generationTrace`).
class GenerationTrace {
  const GenerationTrace({
    this.steps = const [],
    this.selection,
    this.requestedBy,
  });

  final List<GenerationStep> steps;
  final GenerationSelectionTrace? selection;

  /// 'AUTO' (the capture pipeline) or 'MANUAL' (someone pressed the button).
  final String? requestedBy;

  static GenerationTrace? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return GenerationTrace(
      steps: GenerationStep.parseList(raw['steps']),
      selection: GenerationSelectionTrace.tryParse(raw['selection']),
      requestedBy: raw['requestedBy']?.toString(),
    );
  }
}

/// Why the selector refused to spend on a capture.
enum GenerationDeclineReason {
  manifestUnreadable,
  noUsablePhotos,
  insufficientSpread,
  unknown;

  static GenerationDeclineReason parse(Object? raw) => switch (raw.toString()) {
        'MANIFEST_UNREADABLE' => GenerationDeclineReason.manifestUnreadable,
        'NO_USABLE_PHOTOS' => GenerationDeclineReason.noUsablePhotos,
        'INSUFFICIENT_SPREAD' => GenerationDeclineReason.insufficientSpread,
        _ => GenerationDeclineReason.unknown,
      };

  /// Copy safe for anyone to read, saying what to DO about it. Nobody can act
  /// on "INSUFFICIENT_SPREAD"; everybody can act on "walk around the object".
  /// Mirrors the backend's owner-route mapping so the two never disagree.
  String get message => switch (this) {
        GenerationDeclineReason.manifestUnreadable =>
          "We couldn't read this capture. It needs to be captured again.",
        GenerationDeclineReason.noUsablePhotos =>
          'The photos in this capture are too blurry to build a 3D model. '
              'Try capturing again in better light, holding the phone steady.',
        GenerationDeclineReason.insufficientSpread =>
          'This capture only shows one side of the object. Walk all the way '
              'around it and capture again.',
        GenerationDeclineReason.unknown =>
          'These photos cannot support a 3D model.',
      };
}
