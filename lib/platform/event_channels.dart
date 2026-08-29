// lib/platform/event_channels.dart
//
// Capture-loop progress stream (burst / auto-capture): per-frame, completion,
// and error events. Historically this file WAS the native EventChannel wrapper;
// it is now the platform-agnostic face of the same [StillCapturePort]
// method_channels.dart drives — they are two views of ONE capture module, and
// pairing them in one port is what lets the web loop and its event stream stay
// in sync by construction.
//
//   • native → the `captureEvents` EventChannel, unchanged;
//   • web    → the Dart timer loop in
//     capture_ports/still_capture_port_web.dart, emitting the SAME event types.
//
// The event types now live in capture_ports/capture_event_models.dart and are
// re-exported here. Channel name: com.mayasabhaxr.recapture/captureEvents
import 'package:flutter/services.dart';

import 'capture_ports/still_capture_port.dart';
import 'capture_ports/still_capture_port_stub.dart'
    if (dart.library.io) 'capture_ports/still_capture_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/still_capture_port_web.dart';

export 'capture_ports/capture_event_models.dart'
    show
        CaptureEvent,
        CaptureFrameEvent,
        CaptureCompletedEvent,
        CaptureErrorEvent,
        CaptureMetadataEvent;

/// Streams capture events. Unknown/malformed events are filtered out.
class CaptureEvents {
  CaptureEvents([EventChannel? channel])
      : _port = createStillCapturePort(eventsChannel: channel);

  final StillCapturePort _port;

  Stream<CaptureEvent> stream() => _port.events();
}
