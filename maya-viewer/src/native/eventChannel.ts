// src/native/eventChannel.ts

/**
 * A handle returned from EventChannel.subscribe().
 * Consumers hold this to clean up when done.
 */
export interface EventChannelSubscription {
  unsubscribe: () => void;
}

/**
 * Generic event channel abstraction — the public consumer-facing interface.
 * Consumers can subscribe; they cannot emit.
 */
export interface EventChannel<T> {
  subscribe: (callback: (payload: T) => void) => EventChannelSubscription;
}

/**
 * Internal-only emit capability.
 * Combined with EventChannel<T> inside stub/bridge implementations, but never
 * re-exported on the public EventChannel<T> interface so consumers cannot fake
 * native events.
 */
export interface EventChannelEmitter<T> {
  emit: (payload: T) => void;
}
