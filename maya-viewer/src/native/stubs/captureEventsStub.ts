// src/native/stubs/captureEventsStub.ts
import type {
  EventChannel,
  EventChannelEmitter,
  EventChannelSubscription,
} from '../eventChannel';
import type { CaptureEventPayload, CaptureEventsChannel } from '../captureEvents';

/**
 * Stub capture-events channel.
 *
 * Satisfies EventChannel<CaptureEventPayload> for consumers.
 * Internally also implements EventChannelEmitter so tests can push events
 * without a real native bridge — but only CaptureEventsChannel is exported.
 *
 * Behaviour guarantees:
 *   - Multiple independent subscribers are supported.
 *   - Calling unsubscribe() twice does not throw.
 *   - The stub never emits spontaneously — callbacks fire only when emit()
 *     is called externally (e.g. in a test harness).
 */
class CaptureEventsStubImpl
  implements EventChannel<CaptureEventPayload>, EventChannelEmitter<CaptureEventPayload>
{
  private readonly subscribers = new Set<(payload: CaptureEventPayload) => void>();

  subscribe(callback: (payload: CaptureEventPayload) => void): EventChannelSubscription {
    this.subscribers.add(callback);
    let active = true;
    return {
      unsubscribe: () => {
        if (active) {
          this.subscribers.delete(callback);
          active = false;
        }
        // Second call: active is already false — no-op, no throw.
      },
    };
  }

  emit(payload: CaptureEventPayload): void {
    this.subscribers.forEach((cb) => cb(payload));
  }
}

/** Singleton stub. Export as the public channel type only. */
export const captureEventsStub: CaptureEventsChannel = new CaptureEventsStubImpl();
