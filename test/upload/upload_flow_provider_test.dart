// test/upload/upload_flow_provider_test.dart
//
// The seam delegation: [uploadProgressSourceProvider] / [uploadControllerProvider]
// resolve to the ACTIVE flow's live surface when uploadFlowProvider holds one,
// and fall back to the no-op defaults when idle (screen tests keep overriding
// the seams directly — that behavior is pinned by the existing widget tests).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/upload_controller.dart';
import 'package:recapture/application/upload/upload_flow.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/domain/entities/upload_progress.dart';

/// Installs a pre-built flow surface as the notifier's state.
class _FixedFlowNotifier extends UploadFlowNotifier {
  _FixedFlowNotifier(this.flow);

  final UploadFlowProgress flow;

  @override
  UploadFlowProgress? build() => flow;
}

void main() {
  test('idle (no flow): the no-op defaults serve the initial snapshot',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(uploadFlowProvider), isNull);
    expect(container.read(uploadProgressSourceProvider),
        isA<NoUploadProgressSource>());
    expect(container.read(uploadControllerProvider), isA<NoUploadController>());

    final first =
        await container.read(uploadProgressSourceProvider).watch().first;
    expect(first, UploadProgress.initial);
  });

  test('active flow: both seams delegate to the live surface', () async {
    final flow = UploadFlowProgress();
    var cancelRequested = false;
    flow.onCancelRequested = () => cancelRequested = true;

    final container = ProviderContainer(overrides: [
      uploadFlowProvider.overrideWith(() => _FixedFlowNotifier(flow)),
    ]);
    addTearDown(container.dispose);

    // The progress seam IS the flow surface, and its stream is live.
    expect(container.read(uploadProgressSourceProvider), same(flow));
    final seen = <UploadProgress>[];
    final sub =
        container.read(uploadProgressSourceProvider).watch().listen(seen.add);
    addTearDown(sub.cancel);

    flow.markRunning();
    await Future<void>.delayed(Duration.zero);
    expect(seen.last.status, UploadStatus.inProgress);

    // The control seam reaches the SAME flow (the Cancel→Keep-as-Draft path).
    expect(container.read(uploadControllerProvider), same(flow));
    container.read(uploadControllerProvider).cancel();
    expect(cancelRequested, isTrue);
  });

  test('the screen-facing stream provider rides the delegation too', () async {
    final flow = UploadFlowProgress();
    final container = ProviderContainer(overrides: [
      uploadFlowProvider.overrideWith(() => _FixedFlowNotifier(flow)),
    ]);
    addTearDown(container.dispose);

    final states = <AsyncValue<UploadProgress>>[];
    final sub = container.listen(
      uploadProgressProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );
    addTearDown(sub.close);

    flow.markRunning();
    await Future<void>.delayed(Duration.zero);
    expect(
      states.last.valueOrNull?.status,
      UploadStatus.inProgress,
    );
  });
}
