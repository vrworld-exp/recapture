// tests/auto-generation-processor-wiring.test.ts
//
// The WIRING between the capture processor and automatic model generation —
// specifically that the processor hands over `availableKeys`, the S3 listing it
// already performed for the file-count check.
//
// Why this has its own file: the listing is computed for a different reason
// (count verification) and was originally discarded. Without it, a manifest
// entry whose object never landed becomes a presigned URL that 404s inside
// Meshy — a paid generation burnt on a file that isn't there. And the keys must
// be RELATIVE to rawPrefix: absolute bucket keys would match no candidate and
// silently decline every capture, which is the failure mode this guard exists
// to prevent.
//
// The pipeline and the generation service are both mocked — nothing here is
// about what they do, only about what they are handed.
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Types } from 'mongoose';

import { s3Client } from '@/config/s3';
import { toRelativeImageKey } from '@/services/autoPhotoSelectionService';

const maybeAutoGenerateModel = vi.fn(async () => ({ outcome: 'SKIPPED' as const }));
vi.mock('@/services/autoModelGenerationService', () => ({
  maybeAutoGenerateModel: (input: unknown) => maybeAutoGenerateModel(input as never),
}));
vi.mock('@/worker/processors/captureProcessingPipeline', () => ({
  runCaptureProcessing: async () => ({ stage: 'COMPLETED' }),
}));

const { captureProcessingProcessor } = await import(
  '@/worker/processors/captureProcessingProcessor'
);

const RAW_BUCKET = 'test-raw-bucket';
const RAW_PREFIX = 'dev/u1/p1/j1/';

/** Bundle-relative image keys exactly as capture_bundle_packer.dart emits them. */
const IMAGE_KEYS = ['EYE', 'TOP', 'LOW'].flatMap((ring) =>
  Array.from(
    { length: 16 },
    (_, i) => `images/${ring}/${ring.toLowerCase()}_${String(i + 1).padStart(4, '0')}.jpg`
  )
);
/** The one photo the manifest lists but S3 never received. */
const MISSING_KEY = IMAGE_KEYS[0];

function manifestBody(): string {
  return JSON.stringify({
    flowVariant: 'with_bottom',
    config: { segmentCounts: { A: 16, B: 16, C: 16 } },
    summary: { totalPhotos: IMAGE_KEYS.length, warningsCount: 0, overallComplete: true },
    photos: IMAGE_KEYS.map((key, i) => ({
      photoId: `p_${i}`,
      ringName: key.split('/')[1],
      levelCode: key.includes('/EYE/') ? 'A' : key.includes('/TOP/') ? 'B' : 'C',
      segmentIndex: i % 16,
      verdict: 'accepted',
      quality: { blurScore: 120, meanLuminance: 128 },
      orientation: { yawDegrees: (i % 16) * 22.5, pitchDegrees: 90 },
      imagePath: key,
    })),
  });
}

/**
 * S3 with every bundle object present EXCEPT [MISSING_KEY], which is replaced by
 * an unrelated object so the file COUNT still matches expectedFilesCount — the
 * count check cannot catch this, only the key set can.
 */
function mockS3(): void {
  const listed = [
    `${RAW_PREFIX}capture_manifest.json`,
    ...IMAGE_KEYS.filter((k) => k !== MISSING_KEY).map((k) => `${RAW_PREFIX}${k}`),
    `${RAW_PREFIX}images/EYE/stray_9999.jpg`, // keeps the count at 49
  ];
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
  }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand': {
        const body = manifestBody();
        return { Body: { transformToString: async () => body } };
      }
      case 'ListObjectsV2Command':
        return { Contents: listed.map((Key) => ({ Key })), IsTruncated: false };
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  }) as never);
}

function fakeJob() {
  return {
    _id: new Types.ObjectId(),
    projectId: new Types.ObjectId(),
    userId: new Types.ObjectId(),
    state: 'PROCESSING',
    captureVariant: 'with_bottom',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 49,
      uploadedFilesCount: 49,
      checksumAlgo: 'md5',
      rawBucket: RAW_BUCKET,
      rawPrefix: RAW_PREFIX,
      manifestKey: `${RAW_PREFIX}capture_manifest.json`,
    },
  };
}

describe('captureProcessingProcessor → maybeAutoGenerateModel', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    maybeAutoGenerateModel.mockClear();
    mockS3();
  });

  it('passes availableKeys as keys RELATIVE to rawPrefix', async () => {
    await captureProcessingProcessor(fakeJob() as never);

    expect(maybeAutoGenerateModel).toHaveBeenCalledTimes(1);
    const { availableKeys } = maybeAutoGenerateModel.mock.calls[0]![0] as {
      availableKeys: string[];
    };
    expect(availableKeys).toBeDefined();
    // Relative, not absolute — an absolute key matches no manifest candidate.
    expect(availableKeys.every((k) => !k.startsWith(RAW_PREFIX))).toBe(true);
    expect(availableKeys).toContain('images/EYE/eye_0002.jpg');
    expect(availableKeys).toContain('capture_manifest.json');
    // ...and in the same shape the selector resolves manifest paths into.
    expect(availableKeys).toContain(toRelativeImageKey('images/TOP/top_0001.jpg'));
  });

  it('excludes a manifest entry whose S3 object never landed', async () => {
    await captureProcessingProcessor(fakeJob() as never);

    const { availableKeys } = maybeAutoGenerateModel.mock.calls[0]![0] as {
      availableKeys: string[];
    };
    expect(availableKeys).not.toContain(MISSING_KEY);
    // The count check passed (49 == 49) — only the key set reveals the gap.
    expect(availableKeys).toHaveLength(49);
  });

  it('never fails the capture job when generation throws', async () => {
    maybeAutoGenerateModel.mockRejectedValueOnce(new Error('meshy down'));

    const result = await captureProcessingProcessor(fakeJob() as never);

    expect((result as { validated: boolean }).validated).toBe(true);
  });
});
