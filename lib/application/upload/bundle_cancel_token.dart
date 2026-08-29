// lib/application/upload/bundle_cancel_token.dart
//
// Cooperative cancellation for a bundle pack, lifted out of
// capture_bundle_packer.dart so the upload flow can name the type without
// importing the `dart:io` packer — which matters on web, where that packer is
// never the one that runs.
//
// The packer (native) checks [isCancelled] between files and before each heavy
// stage; the web packer checks it between frames and before the manifest write.
// Both abort promptly and clean up whatever they had staged.
class BundleCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
