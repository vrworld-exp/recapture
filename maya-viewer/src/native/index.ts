// src/native/index.ts — barrel export for all native channel contracts and stubs.

// ── Core interfaces ──────────────────────────────────────────────────────────
export type {
  EventChannelSubscription,
  EventChannel,
  EventChannelEmitter,
} from './eventChannel';

// ── sensorStream ─────────────────────────────────────────────────────────────
export { SENSOR_STREAM_EVENT } from './sensorStream';
export type { SensorStreamPayload, SensorStreamChannel } from './sensorStream';

// ── captureEvents ────────────────────────────────────────────────────────────
export { CAPTURE_EVENT_TYPES } from './captureEvents';
export type {
  CaptureEventType,
  CaptureEventPayload,
  CaptureEventsChannel,
} from './captureEvents';

// ── Stubs ─────────────────────────────────────────────────────────────────────
export { sensorStreamStub } from './stubs/sensorStreamStub';
export { captureEventsStub } from './stubs/captureEventsStub';
