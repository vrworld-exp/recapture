// ios/Runner/UploadEventStreamHandler.swift
import Flutter

/// FlutterStreamHandler for the upload_events EventChannel: wires the Dart
/// subscription's sink into [BackgroundUploadManager] (which buffers events
/// fired while no sink is attached and flushes them here on subscribe). Detach
/// on cancel so a torn-down engine never receives a stale emission.
final class UploadEventStreamHandler: NSObject, FlutterStreamHandler {

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    BackgroundUploadManager.shared.setEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    BackgroundUploadManager.shared.setEventSink(nil)
    return nil
  }
}
