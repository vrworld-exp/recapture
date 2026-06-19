import UIKit
import Flutter
import FirebaseCore

@main
@objc class AppDelegate: FlutterAppDelegate {

  /// Lives for the app's lifetime — owns the native camera-preview
  /// AVCaptureSession + its start/stop/dispose channel (see CameraPreviewManager).
  private var cameraPreviewManager: CameraPreviewManager?

  /// Strong reference to the device-motion stream handler so the
  /// FlutterEventChannel keeps a live delegate (see SensorStreamHandler).
  private var sensorStreamHandler: SensorStreamHandler?

  /// Strong reference to the smoothed-orientation (imu_orientation) stream
  /// handler so its FlutterEventChannel keeps a live delegate (see
  /// ImuOrientationStreamHandler).
  private var imuOrientationStreamHandler: ImuOrientationStreamHandler?

  /// Strong reference to the real-time blur analyzer so its FlutterEventChannel
  /// keeps a live delegate; its video-data output is attached to the preview
  /// session by the camera manager (see BlurAnalysisManager).
  private var blurAnalysisManager: BlurAnalysisManager?

  /// Strong reference to the still-capture manager; its AVCapturePhotoOutput is
  /// attached to the preview session by the camera manager (see CameraCaptureManager).
  private var cameraCaptureManager: CameraCaptureManager?

  /// Strong reference to the app-scoped capture-storage channel handler so its
  /// FlutterMethodChannel keeps a live handler (see CaptureStorageChannelHandler).
  private var captureStorageHandler: CaptureStorageChannelHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Firebase initialization
    FirebaseApp.configure()

    GeneratedPluginRegistrant.register(with: self)

    registerCameraPreview()
    registerSensorStream()
    registerImuOrientationStream()
    registerCaptureStorage()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Registers the app-scoped capture-storage `FlutterMethodChannel` — the iOS
  /// counterpart to the Android `capture_storage` dispatch, serving the SAME
  /// contract the shared Dart `CaptureStorageClient` drives (accounting, free space,
  /// incomplete-job listing, and the project-deletion delete/purge/sweep hooks). All
  /// blocking I/O runs off the platform thread inside the handler. See
  /// CaptureStorageChannelHandler.
  private func registerCaptureStorage() {
    guard let registrar = registrar(forPlugin: "CaptureStoragePlugin") else { return }
    let handler = CaptureStorageChannelHandler()
    captureStorageHandler = handler
    let channel = FlutterMethodChannel(
      name: CaptureStorageChannelHandler.channelName,
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      handler.handle(call, result: result)
    }
  }

  /// Registers the smoothed-orientation `FlutterEventChannel` (CMDeviceMotion
  /// attitude → low-pass-filtered yaw/pitch/roll + quaternion at 50–100 Hz),
  /// the iOS counterpart to the Android imu_orientation channel. The handler is
  /// retained for the app's lifetime. See ImuOrientationStreamHandler.
  private func registerImuOrientationStream() {
    guard let registrar = registrar(forPlugin: "ImuOrientationPlugin") else { return }
    let handler = ImuOrientationStreamHandler()
    imuOrientationStreamHandler = handler
    let channel = FlutterEventChannel(
      name: ImuOrientationStreamHandler.channelName,
      binaryMessenger: registrar.messenger())
    channel.setStreamHandler(handler)
  }

  /// Registers the device-motion `FlutterEventChannel` (CMDeviceMotion attitude →
  /// yaw/pitch/roll). Updates start on subscribe and stop on cancel; the handler
  /// is retained for the app's lifetime. See SensorStreamHandler.
  private func registerSensorStream() {
    guard let registrar = registrar(forPlugin: "SensorStreamPlugin") else { return }
    let handler = SensorStreamHandler()
    sensorStreamHandler = handler
    let channel = FlutterEventChannel(
      name: SensorStreamHandler.channelName,
      binaryMessenger: registrar.messenger())
    channel.setStreamHandler(handler)
  }

  /// Registers the native camera-preview MethodChannel (start/stop/dispose,
  /// parity with the Android contract) and the `UiKitView` platform-view factory
  /// that embeds the live AVCaptureVideoPreviewLayer. Scope is preview only.
  private func registerCameraPreview() {
    guard let registrar = registrar(forPlugin: "CameraPreviewPlugin") else { return }
    let channel = FlutterMethodChannel(
      name: CameraPreviewManager.channelName,
      binaryMessenger: registrar.messenger())
    let manager = CameraPreviewManager(channel: channel)
    cameraPreviewManager = manager
    channel.setMethodCallHandler { call, result in
      manager.handle(call, result: result)
    }
    registrar.register(
      CameraPreviewViewFactory(manager: manager),
      withId: CameraPreviewViewFactory.viewType)

    // Real-time blur analyzer: its AVCaptureVideoDataOutput is attached into the
    // preview session by the manager; results stream over the blur EventChannel.
    let blur = BlurAnalysisManager()
    blurAnalysisManager = blur
    manager.blurAnalyzer = blur
    FlutterEventChannel(
      name: BlurAnalysisManager.channelName,
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(blur)

    // Still-capture: its AVCapturePhotoOutput is attached into the same preview
    // session by the manager. captureSingle returns over the capture MethodChannel;
    // the captureEvents EventChannel is registered ready for the burst follow-up.
    let capture = CameraCaptureManager()
    cameraCaptureManager = capture
    manager.captureManager = capture
    FlutterMethodChannel(
      name: CameraCaptureManager.channelName,
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      capture.handle(call, result: result)
    }
    FlutterEventChannel(
      name: CameraCaptureManager.eventsChannelName,
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(capture)
  }

  // Deep link handling for go_router
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }
}
