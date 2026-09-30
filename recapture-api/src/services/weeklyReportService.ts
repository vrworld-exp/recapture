// src/services/weeklyReportService.ts
//
// The weekly value report (more-customization Stage 9): what Mirage did for a
// restaurant last week, in numbers an owner reads in twenty seconds.
//
// THREE JOBS, in this file on purpose so they cannot drift:
//   1. BUILD — `buildWeeklyReport` reads Mirage's reports for one Monday→Sunday
//      week in Asia/Kolkata, plus our own QR scan rollup and products, and runs
//      the insight rules over them. No writes.
//   2. STORE + TELL — `deliverWeeklyReport` (the worker's entry point) stores
//      the report under its unique (catalog, week) key and sends the owner ONE
//      keyed notification. Both writes are idempotent, so a retried or doubled
//      job is one report and one message.
//   3. READ — the owner's and the delegated rep's history and single-report
//      reads, and the owner's on/off preference.
//
// THE SCOPE IS NEVER CLIENT-SUPPLIED, exactly as in catalogAnalyticsService:
// the Mirage restaurant id comes from the catalog row, and every per-product
// row Mirage returns is checked against it before it is used.
import { Types } from 'mongoose';

import { CLOUDFRONT_BASE } from '@/config/s3';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { Notification } from '@/models/Notification';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { QrScanDaily } from '@/models/QrScanDaily';
import { WeeklyReport } from '@/models/WeeklyReport';
import type {
  CatalogReportPrefs,
  WeeklyReportDish,
  WeeklyReportMetrics,
  WeeklyReportTip,
} from '@/models/types/weeklyReport.types';
import { ANALYTICS_TIMEZONE, dayStringInZone } from '@/services/catalogAnalyticsService';
import { pickTips, type InsightContext, type InsightDishStats } from '@/services/insights/rules';
import { getMirageClient, MirageError } from '@/services/mirage';

/** Below this many menu views the week is "quiet": stored, but no numbers notification. */
export const WEEKLY_REPORT_MIN_VIEWS = 10;
/** Below this many views in the PREVIOUS week, a delta is null rather than "▲ 400%". */
export const WEEKLY_REPORT_MIN_DELTA_BASE = 20;
/** When on Monday (Asia/Kolkata) last week's reports may start going out. */
export const WEEKLY_REPORT_SEND_HOUR = 9;
export const WEEKLY_REPORT_SEND_MINUTE = 30;
/** How many weeks the history screen lists. */
export const WEEKLY_REPORT_HISTORY_WEEKS = 12;
/** The in-app route a report notification opens (`lib/app/routes/app_router.dart`). */
export const WEEKLY_REPORT_ROUTE_PREFIX = '/catalog/reports';

export const DEFAULT_REPORT_PREFS: CatalogReportPrefs = { weekly: true, channels: ['IN_APP'] };

const DAY_MS = 86_400_000;
const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

// ── Week arithmetic (Asia/Kolkata) ─────────────────────────────────────────

/** `YYYY-MM-DD` plus `days` calendar days — string arithmetic, no zone. */
export function addDaysToKey(dayKey: string, days: number): string {
  return new Date(new Date(`${dayKey}T00:00:00.000Z`).getTime() + days * DAY_MS)
    .toISOString()
    .slice(0, 10);
}

/** 0 = Monday … 6 = Sunday, for a day key. */
function weekdayOfKey(dayKey: string): number {
  return (new Date(`${dayKey}T00:00:00.000Z`).getUTCDay() + 6) % 7;
}

/**
 * The Monday of the most recent COMPLETE week as of `now`, in Asia/Kolkata. At
 * 01:00 IST on a Monday the week that just ended is the one before today — its
 * Sunday closed an hour ago.
 */
export function lastCompletedWeekStart(now: Date): string {
  const today = dayStringInZone(now, ANALYTICS_TIMEZONE);
  const thisMonday = addDaysToKey(today, -weekdayOfKey(today));
  return addDaysToKey(thisMonday, -7);
}

/**
 * Whether last week's reports may go out yet: any time from Monday 09:30 IST
 * onward. A worker that slept through Monday morning sends late, never early —
 * the same only-late rule as the subscription sweep.
 */
export function isReportSendTime(now: Date): boolean {
  const today = dayStringInZone(now, ANALYTICS_TIMEZONE);
  if (weekdayOfKey(today) !== 0) return true;
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: ANALYTICS_TIMEZONE,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(now);
  const hour = Number(parts.find((p) => p.type === 'hour')?.value ?? 0);
  const minute = Number(parts.find((p) => p.type === 'minute')?.value ?? 0);
  return hour * 60 + minute >= WEEKLY_REPORT_SEND_HOUR * 60 + WEEKLY_REPORT_SEND_MINUTE;
}

/** "22–28 Sep", or "29 Sep – 5 Oct" across a month. */
export function formatWeekLabel(weekStart: string): string {
  const end = addDaysToKey(weekStart, 6);
  const fmt = (key: string, withMonth: boolean): string =>
    new Intl.DateTimeFormat('en-IN', {
      timeZone: 'UTC',
      day: 'numeric',
      ...(withMonth ? { month: 'short' } : {}),
    }).format(new Date(`${key}T00:00:00.000Z`));
  return weekStart.slice(5, 7) === end.slice(5, 7)
    ? `${fmt(weekStart, false)}–${fmt(end, true)}`
    : `${fmt(weekStart, true)} – ${fmt(end, true)}`;
}

/** "Saturday 8–9 pm". */
export function formatSlot(dow: number, hour: number): string {
  const h12 = (h: number): string => String(h % 12 === 0 ? 12 : h % 12);
  const suffix = (h: number): string => (h % 24 < 12 ? 'am' : 'pm');
  const next = (hour + 1) % 24;
  const range =
    suffix(hour) === suffix(next)
      ? `${h12(hour)}–${h12(next)} ${suffix(next)}`
      : `${h12(hour)} ${suffix(hour)}–${h12(next)} ${suffix(next)}`;
  return `${WEEKDAYS[dow] ?? ''} ${range}`.trim();
}

// ── Build ──────────────────────────────────────────────────────────────────

const num = (value: unknown): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0;
const str = (value: unknown): string => (typeof value === 'string' ? value : '');
const list = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? (value as Record<string, unknown>[]) : [];

/** Percent change, one decimal; null from zero. */
function relativeChange(current: number, previous: number): number | null {
  if (previous <= 0) return null;
  return Math.round(((current - previous) / previous) * 1000) / 10;
}

/** Percent change, one decimal; null on too small a base. */
export function deltaPct(current: number, previous: number | null): number | null {
  if (previous === null || previous < WEEKLY_REPORT_MIN_DELTA_BASE) return null;
  return relativeChange(current, previous);
}

/**
 * Rows grouped by restaurant must name OURS. A row naming another restaurant —
 * or none — is dropped: if Mirage's grouping ever changes, the symptom is a
 * missing dish, never another business's dish in this owner's report.
 */
function ownRows(rows: Record<string, unknown>[], restaurantId: string): Record<string, unknown>[] {
  return rows.filter((row) =>
    row.restaurantId === undefined ? true : String(row.restaurantId) === restaurantId
  );
}

/**
 * An optional Mirage report: an older Mirage without it, or one failing, is an
 * empty list — the report is still worth sending without card impressions.
 */
async function optionalReport(
  run: (() => Promise<unknown[]>) | undefined
): Promise<Record<string, unknown>[]> {
  if (!run) return [];
  try {
    return list(await run());
  } catch (err) {
    if (!(err instanceof MirageError)) throw err;
    console.warn(`[weekly-report] optional report unavailable (${err.code})`);
    return [];
  }
}

interface ProductRow {
  _id: Types.ObjectId;
  name: string;
  type: 'THREE_D' | 'IMAGE_ONLY';
  description?: string;
  availability: 'IN_STOCK' | 'OUT_OF_STOCK';
  mirageItemId?: string;
  assets?: { imageKey?: string; thumbnailUrl?: string };
}

function thumbnailOf(product: ProductRow): string | undefined {
  if (product.assets?.thumbnailUrl) return product.assets.thumbnailUrl;
  if (product.assets?.imageKey) return `${CLOUDFRONT_BASE}/${product.assets.imageKey}`;
  return undefined;
}

/** Pre-printed standee scans for the week, over every code ever pointed at this catalog. */
async function qrScansFor(catalogId: Types.ObjectId, weekStart: string): Promise<number> {
  const assignments = await QrCodeAssignment.find({ catalogId }).select({ _id: 1 }).lean().exec();
  if (assignments.length === 0) return 0;
  // QrScanDaily buckets on UTC days (see its `day` field), so the week here is
  // Monday→Sunday UTC — at most 5½ hours off the IST week at each end, and
  // the only rollup there is. Re-bucketing would need per-scan rows.
  const rows = await QrScanDaily.aggregate<{ total: number }>([
    {
      $match: {
        assignmentId: { $in: assignments.map((a) => a._id) },
        day: { $gte: weekStart, $lte: addDaysToKey(weekStart, 6) },
      },
    },
    { $group: { _id: null, total: { $sum: '$count' } } },
  ]).exec();
  return rows[0]?.total ?? 0;
}

export interface BuiltWeeklyReport {
  metrics: WeeklyReportMetrics;
  tips: WeeklyReportTip[];
}

type BuildCatalog = Pick<
  ICatalog,
  'draftRevision' | 'publishedRevision' | 'lastPublishedAt' | 'mirageRestaurantId'
> & { _id: Types.ObjectId };

/**
 * Builds one catalog's report for the week starting `weekStart` (a Monday).
 *
 * The three core Mirage reports (summary, daily timeseries, top products) must
 * all answer — a MirageError from any of them propagates, and the worker's
 * retry is the right response to "Mirage is asleep". The item funnel and the
 * hourly grid are optional (see {@link optionalReport}).
 */
export async function buildWeeklyReport(
  catalog: BuildCatalog,
  weekStart: string,
  now: Date = new Date()
): Promise<BuiltWeeklyReport> {
  const restaurantId = catalog.mirageRestaurantId;
  if (!restaurantId) throw new Error('buildWeeklyReport: catalog is not provisioned');

  const client = getMirageClient();
  const query = {
    restaurantId,
    from: weekStart,
    to: addDaysToKey(weekStart, 6),
    tz: ANALYTICS_TIMEZONE,
  };

  const [summary, timeseries, topRaw, funnelRaw, hourlyRaw, qrScans, products] = await Promise.all([
    client.analyticsSummary(query),
    client.analyticsTimeseries(query),
    client.analyticsTopProducts({ ...query, limit: 10 }),
    optionalReport(client.analyticsItemFunnel?.bind(client, query)),
    optionalReport(client.analyticsHourly?.bind(client, query)),
    qrScansFor(catalog._id, weekStart),
    CatalogProduct.find({ catalogId: catalog._id, deletedAt: null })
      .select({
        _id: 1,
        name: 1,
        type: 1,
        description: 1,
        availability: 1,
        mirageItemId: 1,
        assets: 1,
      })
      .lean<ProductRow[]>()
      .exec(),
  ]);

  const byMirageId = new Map<string, ProductRow>();
  for (const product of products) {
    if (product.mirageItemId) byMirageId.set(product.mirageItemId, product);
  }

  // ── KPIs ──
  const kpis = (summary.kpis ?? {}) as unknown as Record<string, unknown>;
  const prev = summary.previousKpis as unknown as Record<string, unknown> | undefined;
  const menuViews = num(kpis.pageViews);
  const uniqueVisitors = num(kpis.visitors);
  // `ar_view_clicked`, the same count the daily chart and the analytics screen
  // use, so the report and the dashboard agree on "AR views".
  const arViews = num(kpis.arViews);
  const prevViews = prev ? num(prev.pageViews) : null;
  const comparable = prevViews !== null && prevViews >= WEEKLY_REPORT_MIN_DELTA_BASE;

  // ── Top dishes ──
  const topRows = ownRows(list(topRaw), restaurantId);
  const topDishes: WeeklyReportDish[] = topRows.slice(0, 3).map((row) => {
    const local = byMirageId.get(str(row.productId));
    return {
      catalogProductId: local ? String(local._id) : null,
      name: local?.name ?? (str(row.name) || 'Unknown dish'),
      views: num(row.views),
      arViews: num(row.arViews),
      ...(local && thumbnailOf(local) ? { thumbnailUrl: thumbnailOf(local) } : {}),
    };
  });

  // ── Busiest hour + heat strip ──
  const hourly: number[][] = Array.from({ length: 7 }, () => new Array<number>(24).fill(0));
  let busiestSlot: WeeklyReportMetrics['busiestSlot'] = null;
  for (const row of hourlyRaw) {
    const dow = num(row.dow);
    const hour = num(row.hour);
    const views = num(row.views);
    if (dow < 0 || dow > 6 || hour < 0 || hour > 23) continue;
    hourly[dow][hour] = views;
    if (views > 0 && (!busiestSlot || views > busiestSlot.views)) {
      busiestSlot = { dow, hour, views };
    }
  }

  // ── Daily bars ──
  const perDay = new Map(timeseries.map((p) => [String(p.date), num(p.pageViews)]));
  const daily = Array.from({ length: 7 }, (_, i) => {
    const date = addDaysToKey(weekStart, i);
    return { date, menuViews: perDay.get(date) ?? 0 };
  });

  const metrics: WeeklyReportMetrics = {
    menuViews,
    uniqueVisitors,
    qrScans,
    arViews,
    productViews: num(kpis.productViews),
    // Every delta rides on the menu-view base: a week too small to compare
    // views on is too small to compare anything on.
    deltaPct: {
      menuViews: deltaPct(menuViews, prevViews),
      uniqueVisitors: comparable ? relativeChange(uniqueVisitors, num(prev?.visitors)) : null,
      arViews: comparable ? relativeChange(arViews, num(prev?.arViews)) : null,
    },
    topDishes,
    busiestSlot,
    daily,
    hourly,
  };

  // ── Tips ──
  const toStats = (row: Record<string, unknown>): InsightDishStats | null => {
    const local = byMirageId.get(str(row.productId));
    if (!local) return null;
    return {
      productId: String(local._id),
      views: num(row.views),
      impressions: num(row.impressions),
      opens: num(row.opens),
      arViews: num(row.arViews),
    };
  };
  const ctx: InsightContext = {
    now,
    products: new Map(
      products.map((p) => [
        String(p._id),
        {
          id: String(p._id),
          name: p.name,
          type: p.type,
          hasPhoto: Boolean(p.assets?.imageKey || p.assets?.thumbnailUrl),
          hasDescription: Boolean(p.description && p.description.trim().length > 0),
          availability: p.availability,
        },
      ])
    ),
    topDishes: topRows.map(toStats).filter((s): s is InsightDishStats => s !== null),
    funnel: ownRows(funnelRaw, restaurantId)
      .map(toStats)
      .filter((s): s is InsightDishStats => s !== null),
    searches: list(summary.topSearches).map((s) => ({
      query: str(s.query),
      zeroResults: num(s.zeroResults),
    })),
    draftRevision: catalog.draftRevision,
    publishedRevision: catalog.publishedRevision,
    lastPublishedAt: catalog.lastPublishedAt ?? null,
  };

  return { metrics, tips: pickTips(ctx) };
}

// ── Text (shared by every channel) ─────────────────────────────────────────

const arrow = (pct: number | null): string =>
  pct === null
    ? ''
    : pct >= 0
      ? `  (▲ ${pct}% vs previous week)`
      : `  (▼ ${-pct}% vs previous week)`;

/**
 * The notification's words. Kept apart from the in-app write so the WhatsApp
 * template (subscription Stage 6) sends exactly the same text.
 */
export function formatWeeklyReportText(
  catalogName: string,
  weekStart: string,
  report: BuiltWeeklyReport
): { title: string; message: string } {
  const { metrics, tips } = report;
  const n = (value: number): string => value.toLocaleString('en-IN');
  const lines = [
    `👀 ${n(metrics.menuViews)} menu views${arrow(metrics.deltaPct.menuViews)}`,
    `📱 ${n(metrics.qrScans)} QR scans · ${n(metrics.arViews)} AR views`,
  ];
  const top = metrics.topDishes[0];
  if (top) lines.push(`🏆 Top dish: ${top.name} (${n(top.views)} views)`);
  if (metrics.busiestSlot) {
    lines.push(`⏰ Busiest: ${formatSlot(metrics.busiestSlot.dow, metrics.busiestSlot.hour)}`);
  }
  if (tips[0]) lines.push(`💡 Tip: ${tips[0].text}`);
  return {
    title: `📊 ${catalogName} — last week (${formatWeekLabel(weekStart)})`,
    message: lines.join('\n'),
  };
}

// ── Store + tell ───────────────────────────────────────────────────────────

function isDuplicateKey(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === 11000;
}

function clip(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

/** Keyed insert: a duplicate key is "already sent", never an error. */
async function sendKeyed(doc: Record<string, unknown>): Promise<boolean> {
  try {
    await Notification.create(doc);
    return true;
  } catch (err) {
    if (isDuplicateKey(err)) return false;
    // A courtesy layer, never a step: the report is stored and the screen shows it.
    console.warn('[weekly-report] notification write failed', (err as Error).message);
    return false;
  }
}

export const weeklyReportNotificationKey = (catalogId: Types.ObjectId, weekStart: string): string =>
  `weekly-report:${catalogId.toHexString()}:${weekStart}`;

/** At most once a CALENDAR MONTH per catalog — keyed on the week's month. */
export const quietWeekNotificationKey = (catalogId: Types.ObjectId, weekStart: string): string =>
  `weekly-report-quiet:${catalogId.toHexString()}:${weekStart.slice(0, 7)}`;

export type DeliverOutcome =
  | { outcome: 'SENT' | 'QUIET' | 'ALREADY_DONE'; weekStart: string; notified: boolean }
  | { outcome: 'SKIPPED'; reason: 'GONE' | 'NOT_PUBLISHED' | 'OPTED_OUT' };

/**
 * The worker's entry point: build, store, notify — idempotently.
 *
 * Run twice for the same week, the second run finds the stored report and the
 * keyed notification and writes nothing: one report, one message.
 */
export async function deliverWeeklyReport(
  catalogId: Types.ObjectId,
  weekStart: string,
  now: Date = new Date()
): Promise<DeliverOutcome> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null })
    .select({
      _id: 1,
      userId: 1,
      name: 1,
      businessName: 1,
      status: 1,
      mirageRestaurantId: 1,
      draftRevision: 1,
      publishedRevision: 1,
      lastPublishedAt: 1,
      reportPrefs: 1,
    })
    .lean<
      BuildCatalog & {
        userId: Types.ObjectId;
        name: string;
        businessName?: string;
        status: string;
        reportPrefs?: CatalogReportPrefs;
      }
    >()
    .exec();
  if (!catalog) return { outcome: 'SKIPPED', reason: 'GONE' };
  if (catalog.status !== 'PUBLISHED' || !catalog.mirageRestaurantId) {
    return { outcome: 'SKIPPED', reason: 'NOT_PUBLISHED' };
  }
  if (catalog.reportPrefs?.weekly === false) return { outcome: 'SKIPPED', reason: 'OPTED_OUT' };

  const existing = await WeeklyReport.findOne({ catalogId, weekStart }).lean().exec();
  if (existing) return { outcome: 'ALREADY_DONE', weekStart, notified: existing.notified };

  const built = await buildWeeklyReport(catalog, weekStart, now);
  const quiet = built.metrics.menuViews < WEEKLY_REPORT_MIN_VIEWS;

  try {
    await WeeklyReport.create({
      catalogId,
      weekStart,
      metrics: built.metrics,
      tips: built.tips,
      notified: !quiet,
    });
  } catch (err) {
    // A concurrent run stored it first; that run owns the notification too.
    if (isDuplicateKey(err)) return { outcome: 'ALREADY_DONE', weekStart, notified: !quiet };
    throw err;
  }

  const name = catalog.businessName || catalog.name;
  const expiresAt = new Date(now.getTime() + 14 * DAY_MS);
  const base = {
    kind: 'ANALYTICS',
    audienceType: 'USERS',
    audienceUserIds: [catalog.userId],
    expiresAt,
    deletedAt: null,
  };

  if (quiet) {
    await sendKeyed({
      ...base,
      key: quietWeekNotificationKey(catalogId, weekStart),
      title: 'Your menu had a quiet week',
      message: clip(
        `Only ${built.metrics.menuViews} people opened ${name}'s menu last week. ` +
          'Place your QR where customers can see it — on every table and at the counter.',
        500
      ),
      action: { label: 'See report', url: `${WEEKLY_REPORT_ROUTE_PREFIX}/${weekStart}` },
    });
    return { outcome: 'QUIET', weekStart, notified: false };
  }

  const text = formatWeeklyReportText(name, weekStart, built);
  await sendKeyed({
    ...base,
    key: weeklyReportNotificationKey(catalogId, weekStart),
    title: clip(text.title, 80),
    message: clip(text.message, 500),
    action: { label: 'See report', url: `${WEEKLY_REPORT_ROUTE_PREFIX}/${weekStart}` },
  });
  return { outcome: 'SENT', weekStart, notified: true };
}

// ── Read (owner + delegated rep) ───────────────────────────────────────────

export interface WeeklyReportDto {
  weekStart: string;
  weekEnd: string;
  label: string;
  metrics: WeeklyReportMetrics;
  tips: WeeklyReportTip[];
  /** "Saturday 8–9 pm", or null — preformatted so every client says it the same way. */
  busiestLabel: string | null;
  createdAt: string;
}

export interface WeeklyReportSummaryDto {
  weekStart: string;
  label: string;
  menuViews: number;
  deltaPct: number | null;
}

type ReportLean = {
  weekStart: string;
  metrics: WeeklyReportMetrics;
  tips: WeeklyReportTip[];
  createdAt: Date;
};

function toDto(row: ReportLean): WeeklyReportDto {
  const slot = row.metrics.busiestSlot;
  return {
    weekStart: row.weekStart,
    weekEnd: addDaysToKey(row.weekStart, 6),
    label: formatWeekLabel(row.weekStart),
    metrics: row.metrics,
    tips: row.tips ?? [],
    busiestLabel: slot ? formatSlot(slot.dow, slot.hour) : null,
    createdAt: row.createdAt.toISOString(),
  };
}

async function catalogIdForOwner(ownerUserId: string): Promise<Types.ObjectId | null> {
  const catalog = await Catalog.findOne({
    userId: new Types.ObjectId(ownerUserId),
    deletedAt: null,
  })
    .select({ _id: 1 })
    .lean()
    .exec();
  return catalog ? (catalog._id as Types.ObjectId) : null;
}

export type ReportListResult =
  | { outcome: 'OK'; reports: WeeklyReportSummaryDto[]; prefs: CatalogReportPrefs }
  | { outcome: 'NOT_FOUND' };

/** The last {@link WEEKLY_REPORT_HISTORY_WEEKS} reports, newest first, plus the prefs. */
export async function listWeeklyReports(ownerUserId: string): Promise<ReportListResult> {
  const catalog = await Catalog.findOne({
    userId: new Types.ObjectId(ownerUserId),
    deletedAt: null,
  })
    .select({ _id: 1, reportPrefs: 1 })
    .lean<{ _id: Types.ObjectId; reportPrefs?: CatalogReportPrefs }>()
    .exec();
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const rows = await WeeklyReport.find({ catalogId: catalog._id })
    .sort({ weekStart: -1 })
    .limit(WEEKLY_REPORT_HISTORY_WEEKS)
    .select({ weekStart: 1, 'metrics.menuViews': 1, 'metrics.deltaPct': 1 })
    .lean<{ weekStart: string; metrics: Pick<WeeklyReportMetrics, 'menuViews' | 'deltaPct'> }[]>()
    .exec();

  return {
    outcome: 'OK',
    reports: rows.map((row) => ({
      weekStart: row.weekStart,
      label: formatWeekLabel(row.weekStart),
      menuViews: row.metrics?.menuViews ?? 0,
      deltaPct: row.metrics?.deltaPct?.menuViews ?? null,
    })),
    prefs: { ...DEFAULT_REPORT_PREFS, ...(catalog.reportPrefs ?? {}) },
  };
}

export type ReportGetResult = { outcome: 'OK'; report: WeeklyReportDto } | { outcome: 'NOT_FOUND' };

/** One stored report. `latest` returns the newest one. */
export async function getWeeklyReport(
  ownerUserId: string,
  weekStart: string | 'latest'
): Promise<ReportGetResult> {
  const catalogId = await catalogIdForOwner(ownerUserId);
  if (!catalogId) return { outcome: 'NOT_FOUND' };

  const row =
    weekStart === 'latest'
      ? await WeeklyReport.findOne({ catalogId }).sort({ weekStart: -1 }).lean<ReportLean>().exec()
      : await WeeklyReport.findOne({ catalogId, weekStart }).lean<ReportLean>().exec();
  if (!row) return { outcome: 'NOT_FOUND' };
  return { outcome: 'OK', report: toDto(row) };
}

/** The owner's on/off switch. ReCapture-only — no draftRevision bump, nothing to publish. */
export async function updateReportPrefs(
  ownerUserId: string,
  patch: Partial<CatalogReportPrefs>
): Promise<{ outcome: 'OK'; prefs: CatalogReportPrefs } | { outcome: 'NOT_FOUND' }> {
  const catalog = await Catalog.findOne({
    userId: new Types.ObjectId(ownerUserId),
    deletedAt: null,
  })
    .select({ _id: 1, reportPrefs: 1 })
    .lean<{ _id: Types.ObjectId; reportPrefs?: CatalogReportPrefs }>()
    .exec();
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const prefs: CatalogReportPrefs = {
    ...DEFAULT_REPORT_PREFS,
    ...(catalog.reportPrefs ?? {}),
    ...patch,
  };
  await Catalog.updateOne({ _id: catalog._id }, { $set: { reportPrefs: prefs } }).exec();
  return { outcome: 'OK', prefs };
}

// ── Sweep ──────────────────────────────────────────────────────────────────

/**
 * The published, not deleted, not opted-out catalogs that have no report yet
 * for `weekStart` — the sweep's fan-out list.
 */
export async function catalogsDueForReport(
  weekStart: string
): Promise<{ _id: Types.ObjectId; userId: Types.ObjectId }[]> {
  const done = await WeeklyReport.find({ weekStart }).select({ catalogId: 1 }).lean().exec();
  const doneIds = done.map((row) => row.catalogId);
  return Catalog.find({
    status: 'PUBLISHED',
    deletedAt: null,
    mirageRestaurantId: { $exists: true, $ne: null },
    'reportPrefs.weekly': { $ne: false },
    ...(doneIds.length > 0 ? { _id: { $nin: doneIds } } : {}),
  })
    .select({ _id: 1, userId: 1 })
    .lean<{ _id: Types.ObjectId; userId: Types.ObjectId }[]>()
    .exec();
}
