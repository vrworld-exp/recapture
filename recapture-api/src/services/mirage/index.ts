// src/services/mirage/index.ts
//
// The Mirage integration's public surface. Import from '@/services/mirage' —
// nothing outside this folder should reach for mirageClient.ts directly, so the
// day the transport changes there is exactly one file to look at.
//
// Rule from the architecture (§9): routes and other services call
// catalogPublishService / catalogAnalyticsService, which call this. The Flutter
// client never sees any of it.
export {
  assertMirageConfigured,
  isMirageConfigured,
  getMirageClient,
  setMirageClient,
  resetMirageClient,
  resetMirageTransport,
  mirageClient,
  type MirageClient,
} from './mirageClient';

export { MIRAGE_AVAILABILITIES, bytesUpload } from './mirageTypes';

export {
  MirageError,
  MirageErrorCode,
  MIRAGE_CLASSIFICATION_RULES,
  MIRAGE_FAILURE_CLASSES,
  classifyMirageFailure,
  classifyMirageTransportFailure,
  type MirageErrorCodeValue,
  type MirageFailureClass,
} from './mirageErrors';

export type {
  CreateCategoryInput,
  CreateItemInput,
  CreateRestaurantInput,
  DeleteItemOptions,
  DeleteItemResult,
  MirageAddress,
  MirageAnalyticsKpis,
  MirageAnalyticsQuery,
  MirageAnalyticsRange,
  MirageAnalyticsSummary,
  MirageAssetUrls,
  MirageAvailability,
  MirageBytesUpload,
  MirageCategory,
  MirageFileField,
  MirageFileUpload,
  MirageStreamUpload,
  MirageItem,
  MiragePublicCatalog,
  MirageRestaurant,
  MirageSocialLinks,
  MirageTimeseriesPoint,
  MirageTopProductRow,
  UpdateCategoryInput,
  UpdateItemInput,
  UpdateRestaurantInput,
} from './mirageTypes';
