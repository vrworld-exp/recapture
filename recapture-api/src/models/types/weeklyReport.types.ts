// src/models/types/weeklyReport.types.ts
//
// The weekly value report's stored shape (more-customization Stage 9). Lives
// under models/types so the model, the builder and the insight rules can all
// import it without a service importing a service it should not know about.

/** Where a tip's action card takes the owner in the app. */
export const TIP_ACTIONS = [
  /** The product editor for `productId`. */
  'PRODUCT',
  /** The publish screen. */
  'PUBLISH',
  /** 3D model generation for `productId` — the upsell. */
  'MODEL_GENERATION',
  /** The product list, to add what customers searched for. */
  'ADD_PRODUCT',
  /** The QR / standee screen. */
  'QR',
] as const;
export type TipAction = (typeof TIP_ACTIONS)[number];

export const TIP_IDS = [
  'NO_PHOTO_POPULAR',
  'HIGH_VIEW_LOW_OPEN',
  'AR_OUTPERFORMS',
  'SOLD_OUT_VIEWED',
  'NO_DESCRIPTION',
  'DRAFT_NOT_PUBLISHED',
  'SEARCH_NO_RESULT',
] as const;
export type TipId = (typeof TIP_IDS)[number];

export interface WeeklyReportTip {
  id: TipId;
  /** Higher wins. The report keeps the top two. */
  priority: number;
  text: string;
  action: TipAction;
  /** OUR product id, for PRODUCT / MODEL_GENERATION. */
  productId?: string;
}

export interface WeeklyReportDish {
  /** OUR product id, or null when the Mirage row no longer maps to one. */
  catalogProductId: string | null;
  name: string;
  views: number;
  arViews: number;
  /** Card image for the report screen; absent when the dish has none. */
  thumbnailUrl?: string;
}

export interface WeeklyReportMetrics {
  menuViews: number;
  uniqueVisitors: number;
  /** Pre-printed standee scans (QrScanDaily), bucketed on UTC days. */
  qrScans: number;
  arViews: number;
  productViews: number;
  /** Stage 10: diners shown an offer price or combo (`offer_viewed`). Absent on older reports. */
  offerViews?: number;
  /** Stage 11: "My plate" — plates built, their average value, the most-added dish. */
  plates?: { built: number; avgValue: number; topDish: string | null };
  /** Stage 12.1: taps on the Google review button (prompt + contact sheet). */
  reviewTaps?: number;
  /**
   * Percent change against the previous week, one decimal. Null — not 0, not
   * "▲ 400%" — when the previous week had fewer than
   * WEEKLY_REPORT_MIN_DELTA_BASE menu views.
   */
  deltaPct: {
    menuViews: number | null;
    uniqueVisitors: number | null;
    arViews: number | null;
  };
  topDishes: WeeklyReportDish[];
  /** 0 = Monday … 6 = Sunday, hour 0–23 in Asia/Kolkata. Null with no views. */
  busiestSlot: { dow: number; hour: number; views: number } | null;
  /** Seven entries, Monday first. */
  daily: { date: string; menuViews: number }[];
  /** 7 rows (Monday first) × 24 hours of menu views — the heat strip. */
  hourly: number[][];
}

export interface CatalogReportPrefs {
  /** Default true: absent prefs mean the owner gets the report. */
  weekly: boolean;
  channels: ('IN_APP' | 'WHATSAPP')[];
}
