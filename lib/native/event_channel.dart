// lib/native/event_channel.dart
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

  Stream<T> get stream => _channel
      .receiveBroadcastStream()
      .map<T>(decoder)
      .handleError((Object error, StackTrace _) {
        if (error is! MissingPluginException) throw error;
      });
}
