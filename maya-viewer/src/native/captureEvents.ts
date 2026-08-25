// src/native/captureEvents.ts
import type { EventChannel } from './eventChannel';

/** All capture event type constants. Keys used internally; values are the wire strings. */
export const CAPTURE_EVENT_TYPES = {
  SCREENSHOT_TAKEN: 'captureEvents.screenshotTaken',
  AR_SESSION_START: 'captureEvents.arSessionStart',
  AR_SESSION_END: 'captureEvents.arSessionEnd',
  MODEL_INTERACTION: 'captureEvents.modelInteraction',
} as const;

/** Union of all possible capture event type strings. */
export type CaptureEventType =
  (typeof CAPTURE_EVENT_TYPES)[keyof typeof CAPTURE_EVENT_TYPES];

/** Payload emitted for every capture event. */
export interface CaptureEventPayload {
  type: CaptureEventType;
  /** Epoch milliseconds at the time the event occurred. */
  timestamp: number;
  /** ID of the model involved, if applicable. */
  modelId?: string;
  /** Arbitrary additional event metadata. */
  metadata?: Record<string, unknown>;
}

/** Typed alias for a capture-events channel. */
export type CaptureEventsChannel = EventChannel<CaptureEventPayload>;
