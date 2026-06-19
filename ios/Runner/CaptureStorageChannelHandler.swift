import Flutter

/// Flutter ↔ Swift bridge for the app-scoped capture storage backbone — the iOS
/// counterpart of the Android `MainActivity` `capture_storage` dispatch. Owns a
/// `CaptureStorage` and serves the SAME `com.mayasabhaxr.recapture/capture_storage`
/// contract the shared Dart `CaptureStorageClient` already drives, so there are ZERO
/// Dart changes: accounting (`usage`), free space, `listProjects`/`listJobs`,
/// `listIncompleteJobs`, the guarded delete hooks, and the project-deletion
/// purge/sweep.
///
/// Threading: every call does blocking file I/O, so each is snapshotted on the
/// platform thread and run on a dedicated serial `ioQueue`; the `FlutterResult` is
/// dispatched back to main before replying (FlutterResult is not thread-safe). The
/// serial queue also serializes Dart-initiated mutations of the store.
///
/// Frame writing/allocation stays native (the burst task) exactly as on Android —
/// `newFramePath`/`markJobStart`/`markJobComplete` are not exposed over the channel.
final class CaptureStorageChannelHandler {

  static let channelName = CaptureStorage.channelName

  private let storage: CaptureStorage
  private let ioQueue = DispatchQueue(
    label: "com.mayasabhaxr.recapture.storage.io", qos: .userInitiated)

  init(storage: CaptureStorage = .fromApplicationSupport()) {
    self.storage = storage
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Snapshot args on the platform thread; do the blocking work off it.
    let args = call.arguments as? [String: Any]
    let projectId = args?["projectId"] as? String
    let jobId = args?["jobId"] as? String
    let level = args?["level"] as? String
    let force = args?["force"] as? Bool ?? false
    let knownProjectIds = args?["knownProjectIds"] as? [String]
    let method = call.method

    ioQueue.async { [weak self] in
      guard let self = self else { return }
      do {
        let output = try self.dispatch(
          method: method, projectId: projectId, jobId: jobId, level: level,
          force: force, knownProjectIds: knownProjectIds)
        DispatchQueue.main.async {
          if output is NotImplemented {
            result(FlutterMethodNotImplemented)
          } else {
            result(output)
          }
        }
      } catch {
        let (code, message) = Self.mapError(error)
        DispatchQueue.main.async {
          result(FlutterError(code: code, message: message, details: nil))
        }
      }
    }
  }

  /// Sentinel distinguishing an unhandled method from a legitimate `nil` result
  /// (mirrors the Android `NotImplemented` sentinel).
  private struct NotImplemented {}

  private func dispatch(
    method: String, projectId: String?, jobId: String?, level: String?,
    force: Bool, knownProjectIds: [String]?
  ) throws -> Any? {
    switch method {
    case "freeSpace":
      return storage.freeSpaceBytes()
    case "usage":
      return try storage.usage(req(projectId, "projectId"), jobId: jobId, level: level).toMap()
    case "listProjects":
      return storage.listProjects()
    case "listJobs":
      return try storage.listJobs(req(projectId, "projectId"))
    case "listIncompleteJobs":
      return storage.listIncompleteJobs().map { $0.toMap() }
    case "deleteLevel":
      return try storage.deleteLevel(
        req(projectId, "projectId"), req(jobId, "jobId"), req(level, "level"), force: force).toMap()
    case "deleteJob":
      return try storage.deleteJob(req(projectId, "projectId"), req(jobId, "jobId"), force: force).toMap()
    case "deleteProject":
      return try storage.deleteProject(req(projectId, "projectId"), force: force).toMap()
    case "purgeProjectCaptureData":
      return try storage.purgeProject(req(projectId, "projectId"), force: force).toMap()
    case "sweepOrphanedCaptureData":
      return storage.sweepOrphans(knownProjectIds ?? [], force: force).toMap()
    default:
      return NotImplemented()
    }
  }

  /// A required argument was missing — surfaced to Dart as `INVALID_ARGS` (parity
  /// with the Android `projectId!!` NPE → `INVALID_ARGS`).
  private struct MissingArg: Error { let field: String }

  private func req(_ value: String?, _ field: String) throws -> String {
    guard let v = value else { throw MissingArg(field: field) }
    return v
  }

  /// Mirrors the Android error mapping: bad/missing args → `INVALID_ARGS`,
  /// containment escape → `SECURITY`, everything else → `STORAGE_ERROR`.
  private static func mapError(_ error: Error) -> (String, String) {
    switch error {
    case let e as MissingArg:
      return ("INVALID_ARGS", "Missing or invalid argument: \(e.field)")
    case StorageSegments.SegmentError.invalidSegment(let label):
      return ("INVALID_ARGS", "Invalid \(label): must be 1..\(StorageSegments.maxSegmentLen) of [A-Za-z0-9_-].")
    case StorageSegments.SegmentError.containmentEscape:
      return ("SECURITY", "Resolved path escapes the capture base.")
    default:
      return ("STORAGE_ERROR", error.localizedDescription)
    }
  }
}
