// src/native/stubs/sensorStreamStub.ts
import type {
  EventChannel,
  EventChannelEmitter,
  EventChannelSubscription,
} from '../eventChannel';
import type { SensorStreamPayload, SensorStreamChannel } from '../sensorStream';

/**
 * Stub sensor-stream channel.
 *
 * Satisfies EventChannel<SensorStreamPayload> for consumers.
 * Internally also implements EventChannelEmitter so tests can push payloads
 * without a real native bridge — but only SensorStreamChannel is exported.
 *
 * Behaviour guarantees:
 *   - Multiple independent subscribers are supported.
 *   - Calling unsubscribe() twice does not throw.
 *   - The stub never emits spontaneously — callbacks fire only when emit()
 *     is called externally (e.g. in a test harness).
 */
class SensorStreamStubImpl
  implements EventChannel<SensorStreamPayload>, EventChannelEmitter<SensorStreamPayload>
{
  private readonly subscribers = new Set<(payload: SensorStreamPayload) => void>();

  subscribe(callback: (payload: SensorStreamPayload) => void): EventChannelSubscription {
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

  emit(payload: SensorStreamPayload): void {
    this.subscribers.forEach((cb) => cb(payload));
  }
}

/** Singleton stub. Export as the public channel type only. */
export const sensorStreamStub: SensorStreamChannel = new SensorStreamStubImpl();
