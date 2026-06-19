import AVFoundation
import Flutter
import UIKit

/// Factory for the iOS camera-preview `UiKitView`
/// (`com.mayasabhaxr.recapture/camera_preview_view`). Each created platform view
/// is handed the manager's `AVCaptureSession` so its
/// `AVCaptureVideoPreviewLayer` renders the live feed. The session *lifecycle*
/// (start/stop/dispose) is driven separately over the `camera_preview`
/// MethodChannel — see `CameraPreviewManager`. The factory holds the manager
/// weakly; the manager outlives every view (app lifetime).
final class CameraPreviewViewFactory: NSObject, FlutterPlatformViewFactory {

  static let viewType = "com.mayasabhaxr.recapture/camera_preview_view"

  private weak var manager: CameraPreviewManager?

  init(manager: CameraPreviewManager) {
    self.manager = manager
    super.init()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    return CameraPreviewPlatformView(frame: frame, session: manager?.session)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// The embedded `UiKitView`: a `UIView` whose backing layer IS an
/// `AVCaptureVideoPreviewLayer`, so the layer always tracks the view's bounds
/// automatically (no manual frame math, no stretch). It renders the manager's
/// session and keeps the feed upright by updating the preview *connection*
/// orientation on rotation. It owns NO session lifecycle: on dispose it merely
/// detaches from the session (the manager's `stop`/`dispose` releases the
/// camera), so rapid create/dispose never tears the camera down.
final class CameraPreviewPlatformView: NSObject, FlutterPlatformView {

  private let previewView: PreviewUIView

  init(frame: CGRect, session: AVCaptureSession?) {
    previewView = PreviewUIView(frame: frame)
    super.init()

    // Fill the embedded view without stretching (FILL_CENTER, matching the
    // Android wrapper's BoxFit.cover).
    previewView.previewLayer.videoGravity = .resizeAspectFill
    if let session = session {
      previewView.previewLayer.session = session
    }
    previewView.updateOrientation()

    // Re-orient on device rotation (defensive — the app is portrait-locked, so
    // in practice this stays at portrait, but landscape is handled correctly).
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(
      previewView, selector: #selector(PreviewUIView.updateOrientation),
      name: UIDevice.orientationDidChangeNotification, object: nil)
  }

  func view() -> UIView { previewView }

  deinit {
    NotificationCenter.default.removeObserver(
      previewView, name: UIDevice.orientationDidChangeNotification, object: nil)
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
    // Detach from the session — does NOT stop it (lifecycle is the manager's).
    previewView.previewLayer.session = nil
  }
}

/// A `UIView` backed by an `AVCaptureVideoPreviewLayer`. Using `layerClass`
/// means the preview layer == the view's own layer, so UIKit resizes it with
/// the view (`Flutter view resized` edge case handled for free).
final class PreviewUIView: UIView {

  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

  var previewLayer: AVCaptureVideoPreviewLayer {
    // Safe: layerClass guarantees the backing layer's type.
    // swiftlint:disable:next force_cast
    return layer as! AVCaptureVideoPreviewLayer
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // The interface orientation is only knowable once attached to a window.
    updateOrientation()
  }

  /// Keeps the preview upright by setting the connection orientation from the
  /// current interface orientation. Uses the iOS 17 `videoRotationAngle` API
  /// where available, falling back to the deprecated `videoOrientation`.
  @objc func updateOrientation() {
    guard let connection = previewLayer.connection else { return }
    let orientation = window?.windowScene?.interfaceOrientation ?? .portrait

    if #available(iOS 17.0, *) {
      let angle = Self.rotationAngle(for: orientation)
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = Self.videoOrientation(for: orientation)
    }
  }

  /// iOS 17+ rotation angle (degrees, clockwise) for a preview connection.
  /// Portrait → 90 (the only case that matters under the portrait lock).
  @available(iOS 17.0, *)
  private static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
    switch orientation {
    case .portrait: return 90
    case .portraitUpsideDown: return 270
    case .landscapeLeft: return 180
    case .landscapeRight: return 0
    default: return 90
    }
  }

  /// Pre-iOS 17 mapping. `UIInterfaceOrientation` and `AVCaptureVideoOrientation`
  /// share raw values for the matching cases (unlike `UIDeviceOrientation`,
  /// which is inverted for landscape), so a direct raw-value bridge is correct
  /// when driven by the *interface* orientation.
  private static func videoOrientation(
    for orientation: UIInterfaceOrientation
  ) -> AVCaptureVideoOrientation {
    return AVCaptureVideoOrientation(rawValue: orientation.rawValue) ?? .portrait
  }
}
