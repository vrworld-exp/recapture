// lib/native/event_channel.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Base class for typed [EventChannel] wrappers.
///
/// [MissingPluginException] is swallowed — stream yields nothing when no
/// native plugin is registered, which keeps dev builds safe before stubs
/// are wired up.
abstract class NativeEventChannel<T> {
  NativeEventChannel(String channelName, this.decoder)
      : _channel = EventChannel(channelName);

  final EventChannel _channel;
  final T Function(dynamic raw) decoder;

  /// Raw native events with only [MissingPluginException] swallowed (dev builds
  /// before stubs are wired). Subclasses that need custom per-event handling
  /// (e.g. isolating decode failures so one bad frame can't terminate the
  /// subscription) decode this directly instead of [stream].
  @protected
  Stream<dynamic> get rawStream => _channel
      .receiveBroadcastStream()
      .handleError((Object error, StackTrace _) {
        if (error is! MissingPluginException) throw error;
      });

  Stream<T> get stream => rawStream.map<T>(decoder);
}
