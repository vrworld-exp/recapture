// src/worker/processors/menuImportProcessor.ts
//
// The MENU_IMPORT processor (more-customization Stage 13.1): read one import's
// pages with the AI provider and store the draft. All of it lives in
// menuImportService.processImport; this file reads the payload and maps a
// malformed one to a terminal failure. Anthropic API errors (rate limit,
// overload, network) throw — the worker's backoff retries the whole import.
import { processImport } from '@/services/menuImport/menuImportService';
import { NonRetryableJobError, type JobProcessor } from '@/worker/workerTypes';

export const menuImportProcessor: JobProcessor = async (job) => {
  const importId = job.payload?.importId;
  if (typeof importId !== 'string' || !/^[a-f0-9]{24}$/i.test(importId)) {
    throw new NonRetryableJobError(
      'MENU_IMPORT_JOB_MALFORMED',
      'Menu import job payload is malformed'
    );
  }
  const result = await processImport(importId);
  return { importId, ...result };
};
