import Foundation

/// Per-job manifest/marker used to distinguish a COMPLETE job from one INTERRUPTED
/// mid-capture (app killed during a burst) — the iOS counterpart to the Android
/// `JobManifest`, kept wire-compatible (same keys, same `in_progress`/`complete`
/// tokens, same `_manifest.json` name) so either platform can read the other's tree
/// and `CaptureStorage.listIncompleteJobs` behaves identically.
///
/// Written at job start (`inProgress`) and finalized at completion (`complete`); a
/// job dir whose manifest is missing or not `complete` is "incomplete" and can be
/// resumed or cleaned. Encode produces a small JSON object over controlled scalar
/// keys (sanitized ids / numbers / one of two status tokens — no arbitrary JSON), so
/// both encode and parse are pure and unit-testable without a JSON runtime.
struct JobManifest {

  enum Status: String {
    case inProgress = "in_progress"
    case complete = "complete"

    static func fromWire(_ s: String?) -> Status? {
      guard let s = s else { return nil }
      return Status(rawValue: s)
    }
  }

  let projectId: String
  let jobId: String
  let status: Status
  let startedAtMs: Int64
  /// Set only once the job completes.
  let completedAtMs: Int64?
  /// Frames the capture flow reported at completion (informational; nil until complete).
  let frameCount: Int?

  init(
    projectId: String, jobId: String, status: Status, startedAtMs: Int64,
    completedAtMs: Int64? = nil, frameCount: Int? = nil
  ) {
    self.projectId = projectId
    self.jobId = jobId
    self.status = status
    self.startedAtMs = startedAtMs
    self.completedAtMs = completedAtMs
    self.frameCount = frameCount
  }

  var isComplete: Bool { status == .complete }

  /// Manifest file name; lives in the JOB dir (above the `images/` levels).
  static let fileName = "_manifest.json"

  /// Encodes to the JSON shape `parse` reads. `projectId`/`jobId` are allowlisted
  /// (no quotes/backslashes), so manual assembly is safe and dependency-free.
  func encode() -> String {
    let completed = completedAtMs.map { String($0) } ?? "null"
    let frames = frameCount.map { String($0) } ?? "null"
    return "{"
      + "\"projectId\":\"\(projectId)\","
      + "\"jobId\":\"\(jobId)\","
      + "\"status\":\"\(status.rawValue)\","
      + "\"startedAtMs\":\(startedAtMs),"
      + "\"completedAtMs\":\(completed),"
      + "\"frameCount\":\(frames)"
      + "}"
  }

  /// Parses a manifest written by `encode`. Tolerant of key order and absent
  /// optional fields; returns nil only if the required identity/status/start fields
  /// are unreadable (then the job is treated as incomplete, never trusted).
  static func parse(_ text: String) -> JobManifest? {
    guard let projectId = stringField(text, "projectId"),
          let jobId = stringField(text, "jobId"),
          let status = Status.fromWire(stringField(text, "status")),
          let startedAtMs = longField(text, "startedAtMs") else {
      return nil
    }
    let completed = longField(text, "completedAtMs")
    let frames = longField(text, "frameCount").map { Int($0) }
    return JobManifest(
      projectId: projectId, jobId: jobId, status: status, startedAtMs: startedAtMs,
      completedAtMs: completed, frameCount: frames)
  }

  private static func stringField(_ text: String, _ key: String) -> String? {
    return firstGroup(in: text, pattern: "\"\(key)\"\\s*:\\s*\"([^\"]*)\"")
  }

  // Number field; explicit `null` (or absent) → nil.
  private static func longField(_ text: String, _ key: String) -> Int64? {
    return firstGroup(in: text, pattern: "\"\(key)\"\\s*:\\s*(-?\\d+)").flatMap { Int64($0) }
  }

  private static func firstGroup(in text: String, pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges >= 2,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
  }
}
