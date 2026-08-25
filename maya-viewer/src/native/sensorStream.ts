// src/native/sensorStream.ts
import type { EventChannel } from './eventChannel';

/** Unique event name constant for the sensor stream channel. */
export const SENSOR_STREAM_EVENT = 'sensorStream' as const;

/** Payload emitted on every sensor tick. */
export interface SensorStreamPayload {
  /** Epoch milliseconds at the time of the sensor reading. */
  timestamp: number;
  /** Device orientation angles (degrees). */
  orientation: { alpha: number; beta: number; gamma: number };
  /** Raw accelerometer values (m/s²). */
  accelerometer: { x: number; y: number; z: number };
  /** Whether the platform supports DeviceMotion/IMU APIs. */
  deviceMotionSupported: boolean;
}

/** Typed alias for a sensor-stream channel. */
export type SensorStreamChannel = EventChannel<SensorStreamPayload>;
