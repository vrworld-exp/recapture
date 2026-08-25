// ios/Runner/AppDelegate.swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register the capture channel — handled by CaptureModuleController.
    // P3 will add additional channels here (e.g. sensor stream via
    // FlutterEventChannel) following the same pattern.
    guard let controller = window?.rootViewController as? FlutterViewController else {
      fatalError(
        "rootViewController is not a FlutterViewController. " +
        "This should never happen in a pure-Flutter app — check ios/Runner/Main.storyboard."
      )
    }
    _ = CaptureModuleController.register(with: controller.binaryMessenger)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
