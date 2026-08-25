// src/worker/processorRegistry.ts
//
// jobType → processing function lookup. New job types plug in here (via
// registerProcessor in src/worker/index.ts) without touching the polling
// loop. Queue-agnostic by design: this file and processors/* survive the
// planned BullMQ migration unchanged.
import type { JobProcessor } from '@/worker/workerTypes';

const registry = new Map<string, JobProcessor>();

export function registerProcessor(jobType: string, processor: JobProcessor): void {
  if (registry.has(jobType)) {
    throw new Error(`Processor for jobType "${jobType}" is already registered`);
  }
  registry.set(jobType, processor);
}

export function getProcessor(jobType: string): JobProcessor | undefined {
  return registry.get(jobType);
}

export function listRegisteredTypes(): string[] {
  return Array.from(registry.keys());
}
