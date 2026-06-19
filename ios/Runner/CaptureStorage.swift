import Foundation

/// Filesystem backbone for the capture storage hierarchy
/// `<appBase>/recapture/<projectId>/<jobId>/images/<level>/` — the iOS counterpart
/// to the Android `CaptureStorage`, kept behaviourally identical so the shared Dart
/// `CaptureStorageClient` contract (accounting, free space, incomplete-job listing,
/// and the delete/purge/sweep hooks) holds on both platforms.
///
/// It is the storage layer ONLY — it captures nothing, writes no metadata CONTENT
/// (the capture/EXIF tasks do), and does no processing/upload. It resolves the base,
/// creates the nested structure on demand, allocates collision-free frame (+ sidecar)
/// paths, enumerates + accounts for size/space, marks + detects incomplete jobs, and
/// deletes levels/jobs/projects (guarded against active jobs).
///
/// ## App-scoped storage (no permission)
/// The base is **app-scoped** — iOS Application Support (the same persistent,
/// not-user-visible dir `CameraCaptureManager` already writes captures to), the iOS
/// analog of Android's `getExternalFilesDir`. No Photos / storage permission. The
/// `/recapture` tree is rooted under it — never at a shared/user-visible location.
///
/// ## Security (no traversal)
/// Every `projectId`/`jobId`/`level`/`frameId` is sanitized by `StorageSegments`
/// (strict allowlist) before it touches a path, and each resolved dir/file is
/// re-asserted to stay under `root` via `StorageSegments.assertWithin` — a crafted
/// `../../etc` is rejected, not written.
///
/// ## Concurrency
/// `sequences` (per-level allocation counters) and `activeJobs` are guarded by `lock`,
/// so `newFramePath` is collision-free even if a future burst task calls it off a
/// different queue while the channel handler serves a Dart call on its I/O queue.
///
/// ## Threading
/// All methods perform blocking file I/O and MUST be called off the main thread. They
/// are synchronous; the channel layer (`CaptureStorageChannelHandler`) dispatches
/// Dart-initiated calls to a dedicated serial queue.
final class CaptureStorage {

  static let channelName = "com.mayasabhaxr.recapture/capture_storage"

  // Delete-result codes surfaced to Dart.
  static let codeOk = "ok"
  static let codeActiveJob = "active_job"
  static let codeNotFound = "not_found"
  static let codeIoError = "io_error"

  // Purge-result statuses surfaced to Dart (the project-deletion cleanup hook).
  static let statusOk = "ok"
  static let statusPartial = "partial"
  static let statusRefused = "refused"
  static let statusNoop = "noop"

  /// The `<appBase>/recapture` root. Injected directly so the manager is unit-testable.
  let root: URL
  private let clock: () -> Int64
  private let fm = FileManager.default

  private let lock = NSLock()
  /// Per-level NEXT sequence, keyed by the level dir's standardized path.
  private var sequences: [String: Int64] = [:]
  /// Jobs currently capturing (guards deletes), keyed by `jobKey`.
  private var activeJobs: Set<String> = []

  init(root: URL, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
    self.root = root
    self.clock = clock
  }

  /// Resolves the app-scoped base (Application Support, falling back to the temp dir
  /// if unavailable) and roots `/recapture` under it. Does not create the tree —
  /// directories are made on demand. No permission.
  static func fromApplicationSupport() -> CaptureStorage {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return CaptureStorage(root: base.appendingPathComponent(StorageSegments.rootDir, isDirectory: true))
  }

  // MARK: - results

  struct FramePaths {
    let frameId: String?
    let sequence: Int64
    let framePath: String
    let sidecarPath: String
  }

  struct Usage {
    let frameCount: Int
    let byteCount: Int64
    func toMap() -> [String: Any] { ["frameCount": frameCount, "byteCount": byteCount] }
  }

  struct IncompleteJob {
    let projectId: String
    let jobId: String
    let reason: String
    func toMap() -> [String: Any] { ["projectId": projectId, "jobId": jobId, "reason": reason] }
  }

  struct DeleteResult {
    let ok: Bool
    let code: String
    let filesDeleted: Int
    let bytesFreed: Int64
    func toMap() -> [String: Any] {
      ["ok": ok, "code": code, "filesDeleted": filesDeleted, "bytesFreed": bytesFreed]
    }
  }

  struct PurgeResult {
    let status: String
    let reclaimedBytes: Int64
    let failed: [String]
    func toMap() -> [String: Any] {
      ["status": status, "reclaimedBytes": reclaimedBytes, "failed": failed]
    }
  }

  struct SweepResult {
    let purgedProjects: [String]
    let reclaimedBytes: Int64
    let skipped: [String]
    func toMap() -> [String: Any] {
      ["purgedProjects": purgedProjects, "reclaimedBytes": reclaimedBytes, "skipped": skipped]
    }
  }

  // MARK: - path resolution (sanitized + contained)

  func projectDir(_ projectId: String) throws -> URL {
    try resolve([StorageSegments.require(projectId, "projectId")])
  }

  func jobDir(_ projectId: String, _ jobId: String) throws -> URL {
    try resolve([
      StorageSegments.require(projectId, "projectId"),
      StorageSegments.require(jobId, "jobId"),
    ])
  }

  /// Resolves the level dir, CREATING the nested structure on demand (idempotent).
  func levelDir(_ projectId: String, _ jobId: String, _ level: String) throws -> URL {
    let dir = try resolve([
      StorageSegments.require(projectId, "projectId"),
      StorageSegments.require(jobId, "jobId"),
      StorageSegments.imagesDir,
      StorageSegments.require(level, "level"),
    ])
    try ensureDir(dir)
    return dir
  }

  /// `levelDir` overload that canonicalizes an int level (`0`,`1`,…) consistently.
  func levelDir(_ projectId: String, _ jobId: String, level: Int) throws -> URL {
    try levelDir(projectId, jobId, StorageSegments.level(level))
  }

  /// Resolves a child of `root` from already-or-about-to-be-validated segments.
  private func resolve(_ segments: [String]) throws -> URL {
    var url = root
    for s in segments { url = url.appendingPathComponent(s) }
    try StorageSegments.assertWithin(base: root, child: url)
    return url
  }

  // MARK: - frame allocation (collision-free, concurrency-safe)

  /// Allocates a unique frame + sidecar path in `(projectId, jobId, level)`, creating
  /// the level dir if needed. Safe under concurrent burst writes: the per-level
  /// sequence is guarded and seeded past existing files, so two parallel calls never
  /// collide and a resumed job never overwrites earlier frames.
  func newFramePath(
    _ projectId: String, _ jobId: String, _ level: String, frameId: String? = nil
  ) throws -> FramePaths {
    let dir = try levelDir(projectId, jobId, level)
    let seq = nextSequence(for: dir)
    let names = StorageSegments.frameNames(seq: seq, frameId: frameId)
    let frame = dir.appendingPathComponent(names.frame)
    try StorageSegments.assertWithin(base: root, child: frame)
    return FramePaths(
      frameId: frameId,
      sequence: seq,
      framePath: frame.path,
      sidecarPath: dir.appendingPathComponent(names.sidecar).path)
  }

  /// Per-level counter, seeded once from existing frame files (resume-safe). Returns
  /// the value to use and advances the stored next-value (get-and-increment).
  private func nextSequence(for levelDir: URL) -> Int64 {
    let key = levelDir.standardizedFileURL.path
    lock.lock()
    defer { lock.unlock() }
    if let next = sequences[key] {
      sequences[key] = next + 1
      return next
    }
    let maxSeq = (try? fm.contentsOfDirectory(atPath: levelDir.path))?
      .filter { StorageSegments.isFrame($0) }
      .compactMap { StorageSegments.sequenceOf($0) }
      .max()
    let seed = (maxSeq.map { $0 + 1 }) ?? 0
    sequences[key] = seed + 1
    return seed
  }

  // MARK: - enumeration

  /// Frame files in a level (sorted by name = capture order); empty if none.
  func listFrames(_ projectId: String, _ jobId: String, _ level: String) throws -> [URL] {
    let dir = try resolve([
      StorageSegments.require(projectId, "projectId"),
      StorageSegments.require(jobId, "jobId"),
      StorageSegments.imagesDir,
      StorageSegments.require(level, "level"),
    ])
    let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { StorageSegments.isFrame($0) }
      .sorted()
      .map { dir.appendingPathComponent($0) }
  }

  func listLevels(_ projectId: String, _ jobId: String) throws -> [String] {
    let images = try jobDir(projectId, jobId).appendingPathComponent(StorageSegments.imagesDir)
    return childDirNames(images)
  }

  func listJobs(_ projectId: String) throws -> [String] {
    childDirNames(try projectDir(projectId))
  }

  func listProjects() -> [String] {
    childDirNames(root)
  }

  private func childDirNames(_ dir: URL) -> [String] {
    guard let entries = try? fm.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
      return []
    }
    return entries.filter { isDirectory($0) }.map { $0.lastPathComponent }.sorted()
  }

  // MARK: - accounting + free space

  /// Frame count + total bytes under a scope: a project (jobId/level nil), a job
  /// (level nil), or a single level. Walks lazily so a job with thousands of frames is
  /// streamed, not loaded into memory. `byteCount` is the real on-disk footprint
  /// (frames + sidecars + manifest); `frameCount` counts only `.jpg`.
  func usage(_ projectId: String, jobId: String? = nil, level: String? = nil) throws -> Usage {
    let scope: URL
    if let jobId = jobId, let level = level {
      scope = try resolve([
        StorageSegments.require(projectId, "projectId"),
        StorageSegments.require(jobId, "jobId"),
        StorageSegments.imagesDir,
        StorageSegments.require(level, "level"),
      ])
    } else if let jobId = jobId {
      scope = try jobDir(projectId, jobId)
    } else {
      scope = try projectDir(projectId)
    }
    guard fm.fileExists(atPath: scope.path) else { return Usage(frameCount: 0, byteCount: 0) }
    var frames = 0
    var bytes: Int64 = 0
    for file in regularFiles(under: scope) {
      bytes += fileSize(file)
      if StorageSegments.isFrame(file.lastPathComponent) { frames += 1 }
    }
    return Usage(frameCount: frames, byteCount: bytes)
  }

  /// Usable bytes on the volume holding the capture tree (for pre-burst space checks).
  /// Walks up to the nearest existing ancestor (the root may not exist yet).
  func freeSpaceBytes() -> Int64 {
    var dir: URL? = root
    while let d = dir, !fm.fileExists(atPath: d.path) {
      let parent = d.deletingLastPathComponent()
      dir = (parent.path == d.path) ? nil : parent
    }
    guard let probe = dir else { return 0 }
    if let values = try? probe.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let cap = values.volumeAvailableCapacityForImportantUsage {
      return cap
    }
    if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
      let cap = values.volumeAvailableCapacity {
      return Int64(cap)
    }
    return 0
  }

  // MARK: - job manifest (incomplete-job detection)

  /// Marks a job as started (writes an in-progress manifest; flags it active).
  func markJobStart(_ projectId: String, _ jobId: String) throws {
    let pid = try StorageSegments.require(projectId, "projectId")
    let jid = try StorageSegments.require(jobId, "jobId")
    let dir = try jobDir(pid, jid)
    try ensureDir(dir)
    try writeManifest(dir, JobManifest(
      projectId: pid, jobId: jid, status: .inProgress, startedAtMs: clock()))
    lock.lock(); activeJobs.insert(jobKey(pid, jid)); lock.unlock()
  }

  /// Finalizes a job (writes a complete manifest; clears active). Idempotent.
  func markJobComplete(_ projectId: String, _ jobId: String, frameCount: Int? = nil) throws {
    let pid = try StorageSegments.require(projectId, "projectId")
    let jid = try StorageSegments.require(jobId, "jobId")
    let dir = try jobDir(pid, jid)
    guard fm.fileExists(atPath: dir.path) else { return }
    let started = readManifest(dir)?.startedAtMs ?? clock()
    try writeManifest(dir, JobManifest(
      projectId: pid, jobId: jid, status: .complete, startedAtMs: started,
      completedAtMs: clock(), frameCount: frameCount))
    lock.lock(); activeJobs.remove(jobKey(pid, jid)); lock.unlock()
  }

  /// Lists jobs interrupted mid-capture: a job dir whose manifest is missing
  /// (`no_manifest`, only if it holds frames) or not complete (`in_progress`).
  func listIncompleteJobs() -> [IncompleteJob] {
    var out: [IncompleteJob] = []
    for project in listProjects() {
      let projectDir = root.appendingPathComponent(project)
      for jobDir in childDirURLs(projectDir) {
        let manifest = readManifest(jobDir)
        if manifest == nil {
          if hasAnyFrame(jobDir) {
            out.append(IncompleteJob(projectId: project, jobId: jobDir.lastPathComponent, reason: "no_manifest"))
          }
        } else if !manifest!.isComplete {
          out.append(IncompleteJob(projectId: project, jobId: jobDir.lastPathComponent, reason: manifest!.status.rawValue))
        }
      }
    }
    return out
  }

  func readManifest(_ projectId: String, _ jobId: String) throws -> JobManifest? {
    readManifest(try jobDir(projectId, jobId))
  }

  private func writeManifest(_ jobDir: URL, _ manifest: JobManifest) throws {
    let file = jobDir.appendingPathComponent(JobManifest.fileName)
    try manifest.encode().write(to: file, atomically: true, encoding: .utf8)
  }

  private func readManifest(_ jobDir: URL) -> JobManifest? {
    let file = jobDir.appendingPathComponent(JobManifest.fileName)
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return JobManifest.parse(text)
  }

  private func hasAnyFrame(_ jobDir: URL) -> Bool {
    regularFiles(under: jobDir).contains { StorageSegments.isFrame($0.lastPathComponent) }
  }

  // MARK: - deletion (guarded against active jobs; complete)

  func deleteLevel(_ projectId: String, _ jobId: String, _ level: String, force: Bool = false) throws -> DeleteResult {
    let pid = try StorageSegments.require(projectId, "projectId")
    let jid = try StorageSegments.require(jobId, "jobId")
    if !force && isActive(pid, jid) { return guarded() }
    let dir = try resolve([pid, jid, StorageSegments.imagesDir, StorageSegments.require(level, "level")])
    return deleteTree(dir)
  }

  func deleteJob(_ projectId: String, _ jobId: String, force: Bool = false) throws -> DeleteResult {
    let pid = try StorageSegments.require(projectId, "projectId")
    let jid = try StorageSegments.require(jobId, "jobId")
    if !force && isActive(pid, jid) { return guarded() }
    let result = deleteTree(try jobDir(pid, jid))
    if result.ok { forgetJob(pid, jid) }
    return result
  }

  /// Deletes a project's entire capture tree. Refuses (unless `force`) if ANY job in
  /// the project is active. The hook P1 project-deletion calls to clean a deleted
  /// project's capture data (no orphaned `/recapture` subtree).
  func deleteProject(_ projectId: String, force: Bool = false) throws -> DeleteResult {
    let pid = try StorageSegments.require(projectId, "projectId")
    if !force && hasActiveJob(inProject: pid) { return guarded() }
    let result = deleteTree(try projectDir(pid))
    if result.ok { forgetProject(pid) }
    return result
  }

  /// Purges a project's entire local capture tree (`/recapture/<projectId>/`) — the
  /// project-deletion cleanup hook. Sanitized/exact-match (a crafted id is rejected),
  /// guarded against an active job (`refused`) unless `force`, idempotent (`noop` when
  /// already gone), and reports `partial` + the surviving paths if some files are
  /// locked/in-use. Reconciled with P1's soft delete as purge-on-delete (Option A).
  func purgeProject(_ projectId: String, force: Bool = false) throws -> PurgeResult {
    let pid = try StorageSegments.require(projectId, "projectId")
    if !force && hasActiveJob(inProject: pid) {
      return PurgeResult(status: Self.statusRefused, reclaimedBytes: 0, failed: [])
    }
    let dir = try projectDir(pid)
    guard fm.fileExists(atPath: dir.path) else {
      return PurgeResult(status: Self.statusNoop, reclaimedBytes: 0, failed: [])
    }
    let outcome = purgeTree(dir)
    if outcome.failed.isEmpty {
      forgetProject(pid)
      return PurgeResult(status: Self.statusOk, reclaimedBytes: outcome.bytesFreed, failed: [])
    }
    return PurgeResult(status: Self.statusPartial, reclaimedBytes: outcome.bytesFreed, failed: outcome.failed)
  }

  /// Optional orphan sweep: purges capture trees for projects on disk NOT in
  /// `knownProjectIds` (data left behind by a project deleted while the app was off).
  /// Each orphan goes through `purgeProject`, so the SAME guards/policy apply. A dir
  /// whose name is not a valid project id is left untouched (recorded in `skipped`).
  func sweepOrphans(_ knownProjectIds: [String], force: Bool = false) -> SweepResult {
    let known = Set(knownProjectIds)
    var purged: [String] = []
    var skipped: [String] = []
    var bytes: Int64 = 0
    for project in listProjects() {
      if known.contains(project) { continue }
      let result: PurgeResult
      do {
        result = try purgeProject(project, force: force)
      } catch {
        skipped.append(project) // not a valid project id — never touch it
        continue
      }
      switch result.status {
      case Self.statusOk:
        purged.append(project); bytes += result.reclaimedBytes
      case Self.statusPartial:
        purged.append(project); bytes += result.reclaimedBytes; skipped.append(project)
      case Self.statusRefused:
        skipped.append(project) // a job is active — left for next time
      default:
        break // noop: vanished under us
      }
    }
    return SweepResult(purgedProjects: purged, reclaimedBytes: bytes, skipped: skipped)
  }

  // MARK: - tree delete helpers

  private struct TreeOutcome { let filesDeleted: Int; let bytesFreed: Int64; let failed: [String] }

  /// Deletes `dir` and everything under it bottom-up: a child that fails leaves its
  /// parent behind (reported via the child path, the retryable unit). Only file
  /// failures are collected — a surviving non-empty dir is the expected consequence.
  private func purgeTree(_ dir: URL) -> TreeOutcome {
    guard (try? StorageSegments.assertWithin(base: root, child: dir)) != nil else {
      return TreeOutcome(filesDeleted: 0, bytesFreed: 0, failed: [dir.path])
    }
    var files = 0
    var bytes: Int64 = 0
    var failed: [String] = []
    for entry in bottomUp(dir) {
      if isDirectory(entry) {
        try? fm.removeItem(at: entry) // remove if now empty; ignore if a child survived
      } else {
        let len = fileSize(entry)
        do {
          try fm.removeItem(at: entry)
          files += 1
          bytes += len
        } catch {
          failed.append(entry.path)
        }
      }
    }
    return TreeOutcome(filesDeleted: files, bytesFreed: bytes, failed: failed)
  }

  private func deleteTree(_ dir: URL) -> DeleteResult {
    guard (try? StorageSegments.assertWithin(base: root, child: dir)) != nil else {
      return DeleteResult(ok: false, code: Self.codeIoError, filesDeleted: 0, bytesFreed: 0)
    }
    guard fm.fileExists(atPath: dir.path) else {
      return DeleteResult(ok: true, code: Self.codeNotFound, filesDeleted: 0, bytesFreed: 0)
    }
    var files = 0
    var bytes: Int64 = 0
    for file in regularFiles(under: dir) {
      files += 1
      bytes += fileSize(file)
    }
    do {
      try fm.removeItem(at: dir)
      return DeleteResult(ok: true, code: Self.codeOk, filesDeleted: files, bytesFreed: bytes)
    } catch {
      return DeleteResult(ok: false, code: Self.codeIoError, filesDeleted: 0, bytesFreed: 0)
    }
  }

  private func guarded() -> DeleteResult {
    DeleteResult(ok: false, code: Self.codeActiveJob, filesDeleted: 0, bytesFreed: 0)
  }

  // MARK: - active-job bookkeeping

  /// True while a job is between `markJobStart` and `markJobComplete`.
  func isActive(_ projectId: String, _ jobId: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return activeJobs.contains(jobKey(projectId, jobId))
  }

  private func hasActiveJob(inProject pid: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return activeJobs.contains { $0.hasPrefix(pid + Self.keySep) }
  }

  private func forgetJob(_ pid: String, _ jid: String) {
    lock.lock(); defer { lock.unlock() }
    activeJobs.remove(jobKey(pid, jid))
    let needle = "/" + jid + "/"
    for k in sequences.keys where k.contains(needle) { sequences.removeValue(forKey: k) }
  }

  private func forgetProject(_ pid: String) {
    lock.lock(); defer { lock.unlock() }
    activeJobs = activeJobs.filter { !$0.hasPrefix(pid + Self.keySep) }
    let needle = "/" + pid + "/"
    for k in sequences.keys where k.contains(needle) { sequences.removeValue(forKey: k) }
  }

  private func jobKey(_ projectId: String, _ jobId: String) -> String {
    projectId + Self.keySep + jobId
  }

  private static let keySep = " "

  // MARK: - filesystem helpers

  private func ensureDir(_ dir: URL) throws {
    try StorageSegments.assertWithin(base: root, child: dir)
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  private func fileSize(_ url: URL) -> Int64 {
    let attrs = try? fm.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
  }

  /// All regular files under `dir`, lazily enumerated (skips directories).
  private func regularFiles(under dir: URL) -> [URL] {
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
      return []
    }
    var out: [URL] = []
    for case let url as URL in en where !isDirectory(url) {
      out.append(url)
    }
    return out
  }

  /// Direct child directories of `dir`.
  private func childDirURLs(_ dir: URL) -> [URL] {
    guard let entries = try? fm.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
      return []
    }
    return entries.filter { isDirectory($0) }
  }

  /// All entries under `dir` ordered children-before-parents (for safe rmdir).
  private func bottomUp(_ dir: URL) -> [URL] {
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [dir] }
    var all: [URL] = []
    for case let url as URL in en { all.append(url) }
    // Deepest paths first; the root dir itself appended last.
    all.sort { $0.pathComponents.count > $1.pathComponents.count }
    all.append(dir)
    return all
  }
}
