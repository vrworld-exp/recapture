// lib/domain/catalog/publish_request_result.dart
//
// What asking for a publish can answer.
//
// A SEALED RESULT RATHER THAN AN EXCEPTION, and the reason is the 409. Pressing
// Publish twice — a double tap, a second device, a screen restored after the
// app was backgrounded — is a NORMAL thing for a user to do, and the server's
// answer ("a run is already going, here is its id") is exactly what the screen
// wanted anyway. Modelling that as an error means showing a red message for a
// publish that is running perfectly well, and asking the user to press again.
//
// The same applies to 422 PUBLISH_BLOCKED: the gate list is the payload the
// checklist renders, not an error string. And to NOTHING_TO_RETRY, which is a
// success with zero work — the state the user asked for.
//
// Genuine failures (auth, transport, 5xx, rate limiting) still throw
// [CatalogFailure] from the repository, because there is nothing to render.
import 'publish_gate.dart';

sealed class PublishRequestResult {
  const PublishRequestResult();
}

/// A run was enqueued. Poll `GET /catalog/publish/status` from here.
class PublishQueued extends PublishRequestResult {
  const PublishQueued({required this.runId, this.publicUrl});

  final String runId;

  /// Present when THIS request provisioned the catalog and minted its permanent
  /// URL. Display only — frozen server-side from this moment on.
  final String? publicUrl;
}

/// 409 PUBLISH_IN_PROGRESS. Not an error: the run the caller wanted is already
/// going, and its id is right here.
class PublishAlreadyRunning extends PublishRequestResult {
  const PublishAlreadyRunning(this.runId);

  final String runId;
}

/// 422 PUBLISH_BLOCKED, carrying EVERY failing gate — the server returns the
/// whole set so the checklist can be fixed in one pass rather than in three
/// round trips and three disappointments.
class PublishBlocked extends PublishRequestResult {
  const PublishBlocked(this.gates);

  final List<PublishGate> gates;
}

/// 409 CATALOG_NAME_TAKEN, with the name the server suggests instead.
class PublishNameTaken extends PublishRequestResult {
  const PublishNameTaken(this.suggestedName);

  final String suggestedName;
}

/// A retry with nothing failed. The state the user asked for, so it is a
/// success with no run rather than an error.
class PublishNothingToRetry extends PublishRequestResult {
  const PublishNothingToRetry();
}

/// What `POST /catalog/unpublish` can answer.
sealed class UnpublishResult {
  const UnpublishResult();
}

/// An unpublish run was enqueued.
class UnpublishQueued extends UnpublishResult {
  const UnpublishQueued(this.runId);

  final String runId;
}

/// The catalog was never live. Nothing to take down, and the server says so
/// with a 200 — the outcome the user wanted has already happened.
class UnpublishNotPublished extends UnpublishResult {
  const UnpublishNotPublished();
}

/// A run already holds the catalog; taking it offline has to wait for that run.
class UnpublishAlreadyRunning extends UnpublishResult {
  const UnpublishAlreadyRunning(this.runId);

  final String runId;
}
