// src/modules/asset-pipeline/profiles.ts
//
// Profile loading. Profiles are JSON (not TS constants) so a policy change —
// a texture budget, a size range, a gate — is a data edit reviewable by
// someone who does not read TypeScript, and so a future per-restaurant or
// per-category profile is a new file rather than a code change.
//
// `resolveJsonModule` is on, so these are bundled at build time and there is
// no runtime filesystem read (which would break once the API is packaged).
import foodProfile from './profiles/food.json';
import type { OptimizationProfile } from './types';

const PROFILES: Record<string, OptimizationProfile> = {
  food: foodProfile as OptimizationProfile,
};

export const DEFAULT_PROFILE_NAME = 'food';

export function listProfileNames(): string[] {
  return Object.keys(PROFILES);
}

/**
 * Looks up a profile by name. Throws rather than falling back to a default:
 * a typo'd profile name silently optimizing to the wrong budget is a far worse
 * failure than a job that stops and says which names exist.
 */
export function getProfile(name: string): OptimizationProfile {
  const profile = PROFILES[name];
  if (!profile) {
    throw new Error(
      `Unknown optimization profile "${name}" — available: ${listProfileNames().join(', ')}`
    );
  }
  return profile;
}
