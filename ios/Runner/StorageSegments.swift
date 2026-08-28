import Foundation

/// Pure, framework-free path-segment sanitization + file naming for the capture
/// storage tree `<base>/recapture/<projectId>/<jobId>/images/<level>/` — the iOS
/// counterpart to the Android `StorageSegments` (kept behaviourally identical so
/// both platforms produce the same tree + names and the same Dart contract holds).
///
/// This is the **security boundary**: `projectId`/`jobId`/`level`/`frameId` arrive
/// from outside (project/job ids, capture config) and are interpolated into
/// filesystem paths, so a crafted value like `../../etc` MUST NOT escape the
/// app-scoped base.
///
/// Strategy: a strict allowlist (`[A-Za-z0-9_-]`, 1..`maxSegmentLen`). That
/// inherently rejects `.`, `..`, `/`, `\`, null bytes, whitespace, and every other
/// traversal/encoding trick — there is nothing to "strip"; an invalid segment is
/// simply rejected (`throws`). The manager additionally re-asserts containment with
/// `assertWithin` after resolving (defence in depth). Free of Flutter — unit-testable
/// in isolation.
enum StorageSegments {

  /// Root dir name under the app-scoped base.
  static let rootDir = "recapture"
  /// Fixed segment between `<jobId>` and `<level>`.
  static let imagesDir = "images"
  /// Captured-frame extension; the sidecar mirrors the name with `sidecarExt`.
  static let frameExt = "jpg"
  /// Per-frame JSON sidecar extension (matches `<frame>.json` of the EXIF task).
  static let sidecarExt = "json"

  static let maxSegmentLen = 128

  /// Errors thrown by sanitization / containment. The handler maps these to the
  /// same Flutter error codes the Android side returns.
  enum SegmentError: Error {
    /// An id failed the allowlist. `label` names which (`projectId`/`jobId`/`level`).
    case invalidSegment(label: String)
    /// A resolved path would escape the app-scoped base (containment failure).
    case containmentEscape
  }

  /// A sanitized frame/sidecar name pair within a level dir.
  struct FrameNames {
    let frame: String
    let sidecar: String
  }

  private static let allowed: Set<Character> = {
    var s = Set<Character>()
    s.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    s.formUnion("abcdefghijklmnopqrstuvwxyz")
    s.formUnion("0123456789")
    s.insert("_")
    s.insert("-")
    return s
  }()

  /// True iff `segment` is a safe single path segment (allowlist).
  static func isValid(_ segment: String?) -> Bool {
    guard let segment = segment,
          !segment.isEmpty, segment.count <= maxSegmentLen else { return false }
    return segment.allSatisfy { allowed.contains($0) }
  }

  /// Returns `segment` if valid, else throws `invalidSegment(label)` (the rejected
  /// value is never echoed, to avoid log injection). `label` names which id failed.
  static func require(_ segment: String?, _ label: String) throws -> String {
    guard isValid(segment) else { throw SegmentError.invalidSegment(label: label) }
    return segment!
  }

  /// Canonicalizes a numeric `level` to a stable decimal segment (`0`,`1`,…) so an
  /// int and its string form map to the SAME directory. Negative levels are rejected.
  static func level(_ level: Int) throws -> String {
    guard level >= 0 else { throw SegmentError.invalidSegment(label: "level") }
    return String(level)
  }

  /// Builds the collision-free frame + sidecar names for sequence number `seq` and an
  /// optional caller `frameId`. The zero-padded `seq` (allocated atomically per level
  /// by the manager) guarantees uniqueness even under concurrent burst writes and
  /// regardless of a duplicate/blank/invalid `frameId`; a valid `frameId` is appended
  /// for traceability, an invalid one is dropped (never trusted into the filename).
  static func frameNames(seq: Int64, frameId: String?) -> FrameNames {
    let safeId = isValid(frameId) ? frameId : nil
    let base = safeId != nil
      ? String(format: "%06lld_%@", seq, safeId!)
      : String(format: "%06lld", seq)
    return FrameNames(frame: "\(base).\(frameExt)", sidecar: "\(base).\(sidecarExt)")
  }

  /// Parses the leading sequence number from a frame file name, or nil.
  static func sequenceOf(_ fileName: String) -> Int64? {
    var digits = ""
    for ch in fileName {
      if ch.isNumber { digits.append(ch) } else { break }
    }
    return digits.isEmpty ? nil : Int64(digits)
  }

  /// True iff `name` is a captured frame (`*.jpg`, case-insensitive).
  static func isFrame(_ name: String) -> Bool {
    return name.lowercased().hasSuffix(".\(frameExt)")
  }

  /// Asserts `child` resolves inside `base` (canonical-path containment). The last
  /// line of defence against traversal — throws `containmentEscape` if a resolved
  /// path would escape the app-scoped base.
  static func assertWithin(base: URL, child: URL) throws {
    let basePath = canonical(base)
    let childPath = canonical(child)
    if childPath != basePath && !childPath.hasPrefix(basePath + "/") {
      throw SegmentError.containmentEscape
    }
  }

  private static func canonical(_ url: URL) -> String {
    return url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}
