import Flutter
import QuickLook
import UIKit

/// Native AR Quick Look presenter — the iOS half of
/// `com.mayasabhaxr.recapture/ar_quicklook`.
///
/// WHY THIS EXISTS AT ALL. `<model-viewer>` (inside model_viewer_plus) refuses
/// to enter AR in an app WebView: its `IS_AR_QUICKLOOK_CANDIDATE` short-circuits
/// to a user-agent whitelist (`CriOS/|EdgiOS/|FxiOS/|GSA/|DuckDuckGo/`) as soon
/// as `window.webkit.messageHandlers` exists, which it always does here. So
/// `canActivateAR` never flips and the plugin's own Quick Look intercept never
/// sees a navigation. Handing the CloudFront URL to `launchUrl` instead only
/// opens a browser on the model page — the user then has to find and tap AR a
/// SECOND time. `QLPreviewController` is the only way to land in AR on one tap.
///
/// `QLPreviewController` previews FILES, not URLs, so the USDZ is downloaded
/// first. Downloads are cached under Caches/ar-quicklook keyed by the URL, so
/// re-viewing the same model is instant and the OS can evict the directory
/// under storage pressure without breaking anything.
final class ARQuickLookManager: NSObject {

  static let channelName = "com.mayasabhaxr.recapture/ar_quicklook"

  /// Cache directory for downloaded USDZ files. Caches/ (not Documents/) on
  /// purpose: these are re-downloadable derivatives, must not be backed up,
  /// and the OS may reclaim them whenever it likes.
  private lazy var cacheDirectory: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("ar-quicklook", isDirectory: true)
  }()

  private let downloadQueue = DispatchQueue(
    label: "com.mayasabhaxr.recapture.arquicklook.download", qos: .userInitiated)

  /// The item currently being previewed. Held because
  /// QLPreviewControllerDataSource is queried after `present` returns.
  private var previewItem: ARQuickLookPreviewItem?

  /// Guards against a second present while one is already on screen — a
  /// double-tap would otherwise stack two preview controllers.
  private var isPresenting = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // QLPreviewController is always present; AR mode inside it needs ARKit,
      // which the Dart side never has to reason about — Quick Look degrades to
      // an object viewer by itself on a device without it.
      result(true)

    case "preview":
      guard
        let args = call.arguments as? [String: Any],
        let urlString = args["url"] as? String,
        let url = URL(string: urlString),
        let scheme = url.scheme?.lowercased(),
        scheme == "https"
      else {
        // https only: this URL is handed straight to a system previewer, so a
        // file:// or custom scheme from the Dart side must never be followed.
        result(FlutterError(
          code: "invalid_url",
          message: "A https USDZ url is required.",
          details: nil))
        return
      }
      present(url: url, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(url: URL, result: @escaping FlutterResult) {
    guard !isPresenting else {
      result(FlutterError(
        code: "already_presenting",
        message: "An AR preview is already on screen.",
        details: nil))
      return
    }
    isPresenting = true

    downloadQueue.async { [weak self] in
      guard let self = self else { return }
      do {
        let fileURL = try self.localCopy(of: url)
        DispatchQueue.main.async {
          self.showPreview(fileURL: fileURL, result: result)
        }
      } catch {
        DispatchQueue.main.async {
          self.isPresenting = false
          // The URL never reaches the user — the Dart side maps this to its
          // own copy, same rule as the viewer's load-failure body.
          result(FlutterError(
            code: "download_failed",
            message: "Could not fetch the model for AR.",
            details: nil))
        }
      }
    }
  }

  /// Returns a local `.usdz` file for [url], downloading it on first use.
  ///
  /// The cache key is a hash of the full URL, so the optimizer replacing a
  /// model (a new key under a new prefix) is a different file rather than a
  /// stale hit. The `.usdz` extension is REQUIRED — Quick Look picks its
  /// previewer by path extension, and a file without it opens as a document
  /// rather than in AR.
  private func localCopy(of url: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: cacheDirectory, withIntermediateDirectories: true)

    let cached = cacheDirectory
      .appendingPathComponent(Self.cacheKey(for: url))
      .appendingPathExtension("usdz")
    if fileManager.fileExists(atPath: cached.path) {
      return cached
    }

    let data = try download(url)
    // Write to a temp neighbour then move: a download interrupted midway must
    // never leave a truncated file behind that every later view hits instead.
    let staging = cacheDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: staging, options: .atomic)
    if fileManager.fileExists(atPath: cached.path) {
      try? fileManager.removeItem(at: cached)
    }
    try fileManager.moveItem(at: staging, to: cached)
    return cached
  }

  /// Fetches [url], failing on anything that is not a 2xx.
  ///
  /// The status check is load-bearing: CloudFront answers a missing or
  /// forbidden object with an XML error body and a 403/404. Written to disk
  /// under a `.usdz` name that body becomes a permanently cached "model" that
  /// Quick Look cannot open, and every later view hits the cache instead of
  /// retrying. Runs synchronously on [downloadQueue] — our own serial queue,
  /// never a shared one — so the call site stays linear.
  private func download(_ url: URL) throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60

    var payload: Data?
    var failure: Error?
    var status = 0
    let done = DispatchSemaphore(value: 0)

    URLSession.shared.dataTask(with: request) { data, response, error in
      payload = data
      failure = error
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      done.signal()
    }.resume()
    done.wait()

    if let failure = failure { throw failure }
    guard (200..<300).contains(status), let payload = payload, !payload.isEmpty
    else {
      throw NSError(
        domain: "ARQuickLookManager", code: status,
        userInfo: [NSLocalizedDescriptionKey: "USDZ fetch failed (\(status))."])
    }
    return payload
  }

  /// Stable, filesystem-safe name for a URL. FNV-1a rather than a hash of the
  /// last path component: two models share the `model.usdz` basename and
  /// differ only in their prefix.
  private static func cacheKey(for url: URL) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Array(url.absoluteString.utf8) {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  private func showPreview(fileURL: URL, result: @escaping FlutterResult) {
    guard let presenter = Self.topViewController() else {
      isPresenting = false
      result(FlutterError(
        code: "no_presenter",
        message: "No view controller to present from.",
        details: nil))
      return
    }

    let item = ARQuickLookPreviewItem(fileAt: fileURL)
    // Pinch-to-scale stays on, matching the inline viewer's ArScale.auto:
    // Meshy models carry no calibrated real-world size, so pinning them to
    // "100%" would pin them to a size that is often simply wrong.
    item.allowsContentScaling = true
    // `canonicalWebPageURL` is deliberately NOT set. Setting it makes Quick
    // Look's Share button send that URL instead of the model, which would turn
    // Share into a permanent public link to the CloudFront object — the app
    // never puts an asset URL in front of the user anywhere else (not even in
    // error copy). Left unset, Share sends the 3D file itself.
    previewItem = item

    let controller = QLPreviewController()
    controller.dataSource = self
    controller.delegate = self
    // Reply BEFORE presenting: the Dart side is waiting to drop its pending
    // state, and it must not stay spinning behind a modal the user may sit in
    // for minutes.
    result(true)
    presenter.present(controller, animated: true)
  }

  /// The controller actually on screen. Flutter apps present over the single
  /// FlutterViewController, so walking `presentedViewController` avoids
  /// "attempt to present on a view controller that is already presenting".
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    let root = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?
      .rootViewController
    var top = root
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

extension ARQuickLookManager: QLPreviewControllerDataSource {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewItem == nil ? 0 : 1
  }

  func previewController(
    _ controller: QLPreviewController, previewItemAt index: Int
  ) -> QLPreviewItem {
    previewItem!
  }
}

extension ARQuickLookManager: QLPreviewControllerDelegate {
  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    isPresenting = false
    previewItem = nil
  }
}
