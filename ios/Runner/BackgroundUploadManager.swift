// ios/Runner/BackgroundUploadManager.swift
import Flutter
import Foundation

/// iOS BACKGROUND upload transport: a `URLSession` with a `.background(...)`
/// configuration, so an enqueued upload keeps transferring while the app is
/// suspended — and even after it is killed (the OS relaunches the app to deliver
/// the outcome via `handleEventsForBackgroundURLSession`, see AppDelegate).
///
/// ── Contract (mirrors AppConfig on the Dart side) ────────────────────────────
///   • MethodChannel [methodChannelName] — `enqueueUpload` with
///     { taskID, localPath, uploadURL, headers } enqueues one PUT-from-file task.
///   • EventChannel [eventsChannelName] — pushes progress / success / failure
///     payloads (shapes documented on the Dart `BackgroundUploadEvent` types).
///
/// ── Correctness cruxes ───────────────────────────────────────────────────────
///   • `uploadTask(withRequest:fromFile:)` ONLY — the Data variant is not
///     supported by background sessions (it fails/behaves foreground-only).
///   • `taskDescription` carries our stable `taskID`; `taskIdentifier` is
///     session-scoped and NOT stable across relaunches — never used for
///     correlation.
///   • `isDiscretionary = false`: these are user-triggered uploads, iOS must not
///     defer them to Wi-Fi/charging. (A background session inherently waits for
///     connectivity — the OS-side half of the offline-queue story.)
///   • Task metadata (path/URL/headers/enqueuedAt) is persisted in UserDefaults
///     (recovery bookkeeping, nothing sensitive — tokens in headers are already
///     short-lived presigned/auth values the upload itself carries) so a
///     relaunch can correlate delivered events with their job. Cleared on
///     success and on cancellation; retained on failure for retry/recovery.
///   • The Flutter event sink is NOT thread-safe: every emission is dispatched
///     to the main queue. All mutable state here (sink, buffer, completion
///     handler) is main-queue-confined for the same reason.
///   • Events that fire while no sink is attached (background relaunch before
///     the Dart engine subscribes) are BUFFERED (bounded, 5-minute TTL) and
///     flushed on the next `setEventSink` — a background completion is not lost.
///   • Delegate callbacks stay on completion-handler/delegate patterns — no
///     async/await (NSObject-based delegate, per the task constraint).
///
/// The Dart consumer is `UploadBackgroundSessionClient`
/// (lib/platform/upload_background_session.dart) — iOS-only, no-op elsewhere.
final class BackgroundUploadManager: NSObject {

  static let shared = BackgroundUploadManager()

  /// Background-session identifier — namespaced under the app's bundle id
  /// convention. AppDelegate matches relaunch events against this.
  static let sessionIdentifier = "com.mayasabhaxr.recapture.upload.background"

  /// MethodChannel name — must match AppConfig.channelUploadEngine (Dart).
  static let methodChannelName = "com.mayasabhaxr.recapture/upload_engine"

  /// EventChannel name — must match AppConfig.channelUploadEvents (Dart).
  static let eventsChannelName = "com.mayasabhaxr.recapture/upload_events"

  private static let metadataKey = "bg_upload_tasks"
  private static let maxBufferedEvents = 100
  private static let bufferedEventTTL: TimeInterval = 5 * 60

  /// ISO8601DateFormatter is documented thread-safe (unlike DateFormatter).
  private static let iso8601 = ISO8601DateFormatter()

  private var backgroundSession: URLSession!

  /// The completion handler stored by
  /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
  /// Invoked (once, on the main queue) when `urlSessionDidFinishEvents` fires —
  /// never earlier, even if the Flutter engine is already up. Main-queue-confined.
  var backgroundCompletionHandler: (() -> Void)?

  /// Main-queue-confined. Attached/detached by UploadEventStreamHandler.
  private var eventSink: FlutterEventSink?

  /// Events that fired with no sink attached, oldest first. Main-queue-confined;
  /// bounded and TTL-pruned so a never-subscribing engine can't grow it forever.
  private var pendingEvents: [(bufferedAt: Date, payload: [String: Any])] = []

  private override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
    config.isDiscretionary = false // user-triggered: never defer to Wi-Fi/charging
    config.sessionSendsLaunchEvents = true // relaunch the app for delivery
    backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  // ── MethodChannel dispatch ────────────────────────────────────────────────────

  /// Handles a call from the upload_engine MethodChannel. Validation failures
  /// return a FlutterError BEFORE anything touches the session — a bad path or
  /// URL never creates an orphaned task.
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "enqueueUpload":
      handleEnqueue(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleEnqueue(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let taskID = args["taskID"] as? String, !taskID.isEmpty,
          let localPath = args["localPath"] as? String, !localPath.isEmpty,
          let uploadURLString = args["uploadURL"] as? String else {
      result(FlutterError(
        code: "INVALID_ARGS",
        message: "enqueueUpload requires non-empty taskID, localPath and uploadURL.",
        details: nil))
      return
    }
    let headers = (args["headers"] as? [String: String]) ?? [:]

    guard let uploadURL = URL(string: uploadURLString),
          let scheme = uploadURL.scheme?.lowercased(),
          scheme == "https" || scheme == "http" else {
      result(FlutterError(
        code: "BAD_URL",
        message: "uploadURL is not a valid http(s) URL.",
        details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: localPath) else {
      result(FlutterError(
        code: "FILE_NOT_FOUND",
        message: "No file exists at localPath.",
        details: nil))
      return
    }

    enqueueUpload(
      taskID: taskID,
      localFileURL: URL(fileURLWithPath: localPath),
      uploadURL: uploadURL,
      headers: headers)
    result(nil)
  }

  // ── Enqueue ──────────────────────────────────────────────────────────────────

  /// Enqueues one background PUT of [localFileURL] to [uploadURL]. Metadata is
  /// persisted FIRST so a kill between resume() and the first callback still
  /// leaves a recoverable record.
  func enqueueUpload(
    taskID: String,
    localFileURL: URL,
    uploadURL: URL,
    headers: [String: String]
  ) {
    persistTaskMetadata(
      taskID: taskID, localFileURL: localFileURL, uploadURL: uploadURL, headers: headers)

    var request = URLRequest(url: uploadURL)
    request.httpMethod = "PUT"
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

    // File variant is REQUIRED for background sessions (Data variant unsupported).
    let task = backgroundSession.uploadTask(with: request, fromFile: localFileURL)
    task.taskDescription = taskID // stable cross-relaunch correlation key
    task.resume()
  }

  // ── Event sink (attached by UploadEventStreamHandler) ───────────────────────

  /// Attaches/detaches the Dart event sink. On attach, buffered (non-expired)
  /// events are flushed in order so completions delivered during a background
  /// relaunch reach Dart once it subscribes.
  func setEventSink(_ sink: FlutterEventSink?) {
    DispatchQueue.main.async {
      self.eventSink = sink
      guard let sink = sink else { return }
      self.prunePendingEvents()
      let queued = self.pendingEvents
      self.pendingEvents = []
      for event in queued { sink(event.payload) }
    }
  }

  private func sendToFlutter(event: [String: Any]) {
    DispatchQueue.main.async {
      if let sink = self.eventSink {
        sink(event)
        return
      }
      self.pendingEvents.append((bufferedAt: Date(), payload: event))
      self.prunePendingEvents()
    }
  }

  /// Drops expired events and caps the buffer (oldest first). Main queue only.
  private func prunePendingEvents() {
    let cutoff = Date().addingTimeInterval(-Self.bufferedEventTTL)
    pendingEvents.removeAll { $0.bufferedAt < cutoff }
    if pendingEvents.count > Self.maxBufferedEvents {
      pendingEvents.removeFirst(pendingEvents.count - Self.maxBufferedEvents)
    }
  }

  // ── Task metadata persistence (relaunch recovery) ────────────────────────────

  private func persistTaskMetadata(
    taskID: String, localFileURL: URL, uploadURL: URL, headers: [String: String]
  ) {
    var all = UserDefaults.standard.dictionary(forKey: Self.metadataKey) ?? [:]
    all[taskID] = [
      "localPath": localFileURL.path,
      "uploadURL": uploadURL.absoluteString,
      "headers": headers,
      "enqueuedAt": Self.iso8601.string(from: Date()),
    ]
    UserDefaults.standard.set(all, forKey: Self.metadataKey)
  }

  private func clearTaskMetadata(taskID: String) {
    var all = UserDefaults.standard.dictionary(forKey: Self.metadataKey) ?? [:]
    all.removeValue(forKey: taskID)
    UserDefaults.standard.set(all, forKey: Self.metadataKey)
  }

  private func taskMetadata(for taskID: String) -> [String: Any]? {
    UserDefaults.standard.dictionary(forKey: Self.metadataKey)?[taskID] as? [String: Any]
  }

  /// Whether re-attempting could plausibly succeed: transient NSURLError network
  /// classes → true; cancellation and everything deterministic → false. (HTTP
  /// 4xx never reaches here — a bad status is a "success" at transport level and
  /// the Dart layer classifies its statusCode.)
  private func isRetryable(error: NSError) -> Bool {
    guard error.domain == NSURLErrorDomain else { return false }
    switch error.code {
    case NSURLErrorTimedOut,
         NSURLErrorCannotFindHost,
         NSURLErrorCannotConnectToHost,
         NSURLErrorNetworkConnectionLost,
         NSURLErrorDNSLookupFailed,
         NSURLErrorNotConnectedToInternet,
         NSURLErrorResourceUnavailable,
         NSURLErrorBackgroundSessionWasDisconnected:
      return true
    default:
      return false
    }
  }
}

// ── URLSession delegates ────────────────────────────────────────────────────────

extension BackgroundUploadManager: URLSessionDelegate, URLSessionTaskDelegate,
  URLSessionDataDelegate {

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    let taskID = task.taskDescription ?? "unknown"
    // -1 when the expected length is unknown → Dart renders indeterminate.
    let progress = totalBytesExpectedToSend > 0
      ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
      : -1.0
    sendToFlutter(event: [
      "type": "progress",
      "taskID": taskID,
      "bytesSent": totalBytesSent,
      "totalBytes": totalBytesExpectedToSend,
      "progress": progress,
    ])
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    let taskID = task.taskDescription ?? "unknown"

    if let error = error {
      let nsError = error as NSError
      let cancelled =
        nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      if cancelled {
        // A deliberate cancel is terminal — recovery bookkeeping is cleared.
        // Other failures RETAIN metadata so the job stays recoverable/retryable.
        clearTaskMetadata(taskID: taskID)
      }
      // errorDescription is diagnostics for the Dart classifier — never shown
      // raw to the user (the 9F privacy invariant maps it to a category).
      sendToFlutter(event: [
        "type": "failure",
        "taskID": taskID,
        "errorCode": nsError.code,
        "errorDescription": nsError.localizedDescription,
        "retryRecommended": !cancelled && isRetryable(error: nsError),
      ])
      return
    }

    // Transport success — the HTTP status (incl. 4xx/5xx) rides along for the
    // Dart layer to classify. localPath is echoed from the persisted metadata
    // (read BEFORE clearing) so Dart can correlate file → outcome.
    let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
    let localPath = taskMetadata(for: taskID)?["localPath"] as? String ?? ""
    clearTaskMetadata(taskID: taskID)
    sendToFlutter(event: [
      "type": "success",
      "taskID": taskID,
      "statusCode": statusCode,
      "localPath": localPath,
      "completedAt": Self.iso8601.string(from: Date()),
    ])
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    // All background events delivered → NOW (and only now) invoke the stored
    // OS completion handler, on the main queue (UIKit requirement).
    DispatchQueue.main.async {
      self.backgroundCompletionHandler?()
      self.backgroundCompletionHandler = nil
    }
  }
}
