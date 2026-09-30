// src/worker/processors/weeklyReportProcessor.ts
//
// The WEEKLY_REPORT processor (more-customization Stage 9, Part C): build one
// catalog's report for one week, store it, tell the owner. All of it lives in
// weeklyReportService.deliverWeeklyReport — this file only reads the payload
// and maps failures onto the worker's retry / terminal split.
//
// IDEMPOTENT BY CONSTRUCTION: the report's unique (catalog, week) index and the
// notification's unique key mean a retried or duplicated job writes nothing
// the second time. A Mirage outage is a plain throw → the worker's backoff.
import { Types } from 'mongoose';

import { MirageError, MirageErrorCode } from '@/services/mirage';
import { deliverWeeklyReport } from '@/services/weeklyReportService';
import { NonRetryableJobError, type JobProcessor, type WorkerJob } from '@/worker/workerTypes';

export const WeeklyReportErrorCode = {
  JOB_MALFORMED: 'WEEKLY_REPORT_JOB_MALFORMED',
  AUTH_REJECTED: 'WEEKLY_REPORT_AUTH_REJECTED',
} as const;

function readPayload(job: WorkerJob): { catalogId: Types.ObjectId; weekStart: string } {
  const payload = job.payload ?? {};
  const catalogId = payload.catalogId;
  const weekStart = payload.weekStart;
  if (
    typeof catalogId !== 'string' ||
    !/^[a-f0-9]{24}$/i.test(catalogId) ||
    typeof weekStart !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}$/.test(weekStart)
  ) {
    throw new NonRetryableJobError(
      WeeklyReportErrorCode.JOB_MALFORMED,
      'Weekly report job payload is malformed'
    );
  }
  return { catalogId: new Types.ObjectId(catalogId), weekStart };
}

export const weeklyReportProcessor: JobProcessor = async (job) => {
  const { catalogId, weekStart } = readPayload(job);
  try {
    const result = await deliverWeeklyReport(catalogId, weekStart);
    return { catalogId: catalogId.toHexString(), ...result };
  } catch (err) {
    // A rejected credential does not heal with a retry; everything else from
    // Mirage (asleep, rate-limited, 5xx) does.
    if (err instanceof MirageError && err.code === MirageErrorCode.AUTH_REJECTED) {
      throw new NonRetryableJobError(
        WeeklyReportErrorCode.AUTH_REJECTED,
        'Mirage rejected the analytics credential'
      );
    }
    throw err;
  }
};
