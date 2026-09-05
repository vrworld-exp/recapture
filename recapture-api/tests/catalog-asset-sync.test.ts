// tests/catalog-asset-sync.test.ts
//
// Asset preflight and transfer, with S3 scripted through `vi.spyOn(s3Client,
// 'send')` and Mirage through the fake. No live AWS, no live Mirage.
//
// The assertions that matter most are the two economies, because both are
// invisible when they break — a republish that silently re-uploads 40 MiB still
// SUCCEEDS, and a byte mode that buffers still works right up until the day two
// publishes overlap on a small instance:
//
//   • an unchanged asset performs ZERO GetObject calls;
//   • byte mode never materialises the whole file — the part is a lazy stream
//     factory, and the S3 body is consumed chunk by chunk.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Readable } from 'stream';

import {
  GetObjectCommand,
  HeadObjectCommand,
  type S3Client,
} from '@aws-sdk/client-s3';
import { s3Client } from '@/config/s3';
import { env } from '@/config/env';
import { CLOUDFRONT_BASE } from '@/config/s3';
import { assetSyncUploader } from '@/services/catalog/assetSync';
import { keyFromCdnUrl, preflightAssets } from '@/services/catalog/assetPreflight';
import type { AssetSlot } from '@/services/catalog/assetUploader';
import type { PublishRunContext } from '@/services/catalog/publishExecutors';
import type {
  CatalogSnapshot,
  CatalogSnapshotProduct,
} from '@/services/catalog/publishSnapshot';

// ── S3 script ───────────────────────────────────────────────────────────────

interface StoredObject {
  size: number;
  contentType: string;
  etag: string;
  /** How many chunks the body is delivered in — the streaming-shape probe. */
  chunks?: number;
}

let objects: Map<string, StoredObject>;
let getCalls: string[];
let headCalls: string[];
let send: ReturnType<typeof vi.spyOn>;

function scriptS3(): void {
  objects = new Map();
  getCalls = [];
  headCalls = [];
  send = vi.spyOn(s3Client, 'send').mockImplementation((async (command: unknown) => {
    if (command instanceof HeadObjectCommand) {
      const key = command.input.Key as string;
      headCalls.push(key);
      const found = objects.get(key);
      if (!found) {
        const err = new Error('NotFound') as Error & { name: string };
        err.name = 'NotFound';
        throw err;
      }
      return {
        ContentLength: found.size,
        ContentType: found.contentType,
        ETag: found.etag,
      };
    }
    if (command instanceof GetObjectCommand) {
      const key = command.input.Key as string;
      getCalls.push(key);
      const found = objects.get(key);
      if (!found) {
        const err = new Error('NoSuchKey') as Error & { name: string };
        err.name = 'NoSuchKey';
        throw err;
      }
      const chunkCount = found.chunks ?? 4;
      const chunkSize = Math.ceil(found.size / chunkCount);
      const body = Readable.from(
        (function* () {
          let sent = 0;
          while (sent < found.size) {
            const n = Math.min(chunkSize, found.size - sent);
            sent += n;
            yield Buffer.alloc(n, 7);
          }
        })()
      );
      return { Body: body, ContentType: found.contentType };
    }
    throw new Error(`unscripted S3 command: ${(command as object).constructor.name}`);
  }) as unknown as S3Client['send']);
}

const cdn = (key: string): string => `${CLOUDFRONT_BASE}/${key}`;

const GLB_KEY = 'dev/blue_cafe_aaa/job1/models/m1/model.glb';
const USDZ_KEY = 'dev/blue_cafe_aaa/job1/models/m1/model.usdz';
const PREVIEW_KEY = 'dev/blue_cafe_aaa/job1/models/m1/preview.jpg';
const IMAGE_KEY = 'dev/catalog/cat1/products/p1/img.jpg';

function threeDProduct(overrides: Partial<CatalogSnapshotProduct> = {}): CatalogSnapshotProduct {
  return {
    id: 'p1',
    type: 'THREE_D',
    name: 'Chair',
    categoryId: 'c1',
    position: 0,
    glbUrl: cdn(GLB_KEY),
    usdzUrl: cdn(USDZ_KEY),
    thumbnailUrl: cdn(PREVIEW_KEY),
    syncStatus: 'NEVER',
    ...overrides,
  };
}

function context(): PublishRunContext {
  const snapshot = {
    catalog: {
      id: 'cat1',
      userId: 'u1',
      name: 'Blue Cafe',
      status: 'DRAFT',
      draftRevision: 0,
      publishedRevision: -1,
    },
    categories: [],
    products: [],
    takenAt: new Date(),
  } as unknown as CatalogSnapshot;
  return {
    runId: 'run1',
    catalogId: 'cat1',
    userId: 'u1',
    mode: 'FULL',
    snapshot,
    mirageRestaurantId: 'mr1',
    mirageCategoryIds: new Map(),
    loggedOnce: new Set<string>(),
  };
}

const ALL_SLOTS: AssetSlot[] = ['object', 'objectIos', 'image'];

beforeEach(() => {
  scriptS3();
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ── Key resolution ──────────────────────────────────────────────────────────

describe('keyFromCdnUrl', () => {
  it('inverts the URL construction the whole pipeline uses', () => {
    expect(keyFromCdnUrl(cdn(GLB_KEY))).toBe(GLB_KEY);
  });

  it('refuses a URL that is not on our CDN', () => {
    // A Meshy link that escaped the re-host must never become an S3 key we go
    // and fetch — or worse, one we hand to Mirage.
    expect(keyFromCdnUrl('https://assets.meshy.ai/x/model.glb')).toBeNull();
  });
});

// ── Preflight ───────────────────────────────────────────────────────────────

describe('preflight', () => {
  it('resolves every slot and reports its size and identity', async () => {
    objects.set(GLB_KEY, { size: 1024, contentType: 'model/gltf-binary', etag: '"a"' });
    objects.set(USDZ_KEY, { size: 512, contentType: 'model/vnd.usdz+zip', etag: '"b"' });
    objects.set(PREVIEW_KEY, { size: 256, contentType: 'image/jpeg', etag: '"c"' });

    const result = await preflightAssets(threeDProduct(), ALL_SLOTS, undefined);

    expect(result.outcome).toBe('OK');
    if (result.outcome !== 'OK') return;
    expect(result.assets.map((a) => a.slot)).toEqual(['object', 'objectIos', 'image']);
    expect(result.assets[0]).toMatchObject({ key: GLB_KEY, size: 1024 });
    expect(result.assets[0].identity.etag).toBe('"a"');
    expect(result.assets.every((a) => !a.unchanged)).toBe(true);
  });

  it('rejects a missing object BEFORE any transfer', async () => {
    objects.set(PREVIEW_KEY, { size: 256, contentType: 'image/jpeg', etag: '"c"' });

    const result = await preflightAssets(threeDProduct(), ['object'], undefined);

    expect(result).toMatchObject({
      outcome: 'BLOCKED',
      failure: { code: 'PUBLISH_ASSET_MISSING' },
    });
    expect(getCalls).toHaveLength(0);
  });

  it('rejects an oversize asset BEFORE any transfer', async () => {
    objects.set(GLB_KEY, {
      size: env.MIRAGE_MAX_ASSET_BYTES + 1,
      contentType: 'model/gltf-binary',
      etag: '"a"',
    });

    const result = await preflightAssets(threeDProduct(), ['object'], undefined);

    expect(result).toMatchObject({
      outcome: 'BLOCKED',
      failure: { code: 'PUBLISH_ASSET_TOO_LARGE' },
    });
    expect(getCalls).toHaveLength(0);
  });

  it('rejects an object whose stored content type is wrong for its slot', async () => {
    objects.set(GLB_KEY, { size: 10, contentType: 'text/html', etag: '"a"' });

    const result = await preflightAssets(threeDProduct(), ['object'], undefined);

    expect(result).toMatchObject({
      outcome: 'BLOCKED',
      failure: { code: 'PUBLISH_ASSET_UNSUPPORTED' },
    });
  });

  it('blocks a 3D product whose thumbnail has not been generated yet', async () => {
    objects.set(GLB_KEY, { size: 10, contentType: 'model/gltf-binary', etag: '"a"' });
    const product = threeDProduct({ thumbnailUrl: undefined });

    const result = await preflightAssets(product, ['image'], undefined);

    // Publishing a 3D product with no image gives customers a blank card while
    // the model streams — the refusal is the feature.
    expect(result).toMatchObject({
      outcome: 'BLOCKED',
      failure: { code: 'PUBLISH_ASSET_MISSING' },
    });
    if (result.outcome !== 'BLOCKED') return;
    expect(result.failure.message).toMatch(/preview image is still being generated/i);
  });

  it('uses the committed photo for an image-only product', async () => {
    objects.set(IMAGE_KEY, { size: 99, contentType: 'image/jpeg', etag: '"i"' });
    const product = threeDProduct({
      type: 'IMAGE_ONLY',
      glbUrl: undefined,
      usdzUrl: undefined,
      thumbnailUrl: undefined,
      imageKey: IMAGE_KEY,
    });

    const result = await preflightAssets(product, ['image'], undefined);

    expect(result.outcome).toBe('OK');
    if (result.outcome !== 'OK') return;
    expect(result.assets[0].key).toBe(IMAGE_KEY);
  });

  it('marks an asset unchanged only when the ETag AND the source both match', async () => {
    objects.set(GLB_KEY, { size: 1024, contentType: 'model/gltf-binary', etag: '"a"' });

    const same = await preflightAssets(threeDProduct(), ['object'], {
      object: { source: cdn(GLB_KEY), etag: '"a"', size: 1024 },
    });
    expect(same.outcome === 'OK' && same.assets[0].unchanged).toBe(true);

    // The key was overwritten in place: same URL, different bytes. This is the
    // case a URL comparison cannot see.
    const overwritten = await preflightAssets(threeDProduct(), ['object'], {
      object: { source: cdn(GLB_KEY), etag: '"OLD"', size: 900 },
    });
    expect(overwritten.outcome === 'OK' && overwritten.assets[0].unchanged).toBe(false);

    // No ETag recorded ⇒ we cannot prove it, so we re-push. Erring toward one
    // extra upload beats publishing a model a version behind.
    const unknown = await preflightAssets(threeDProduct(), ['object'], {
      object: { source: cdn(GLB_KEY), size: 1024 },
    });
    expect(unknown.outcome === 'OK' && unknown.assets[0].unchanged).toBe(false);
  });
});

// ── Transfer ────────────────────────────────────────────────────────────────

describe('transfer — byte mode', () => {
  it('produces a lazy stream part per changed slot, opening nothing up front', async () => {
    objects.set(GLB_KEY, { size: 4096, contentType: 'model/gltf-binary', etag: '"a"' });
    objects.set(USDZ_KEY, { size: 512, contentType: 'model/vnd.usdz+zip', etag: '"b"' });
    objects.set(PREVIEW_KEY, { size: 256, contentType: 'image/jpeg', etag: '"c"' });

    const result = await assetSyncUploader({
      product: threeDProduct(),
      slots: ALL_SLOTS,
      context: context(),
    });

    expect(result.outcome).toBe('READY');
    if (result.outcome !== 'READY') return;
    expect(Object.keys(result.files).sort()).toEqual(['image', 'object', 'objectIos']);
    // Preflight HEADed; nothing has been READ. The bytes move only when the
    // multipart encoder reaches the part.
    expect(headCalls).toHaveLength(3);
    expect(getCalls).toHaveLength(0);
  });

  it('never materialises the whole file — the body arrives in chunks', async () => {
    objects.set(GLB_KEY, {
      size: 400_000,
      contentType: 'model/gltf-binary',
      etag: '"a"',
      chunks: 25,
    });

    const result = await assetSyncUploader({
      product: threeDProduct({ usdzUrl: undefined, thumbnailUrl: undefined }),
      slots: ['object'],
      context: context(),
    });
    if (result.outcome !== 'READY') throw new Error('expected READY');
    const part = result.files.object;
    if (!part || part.kind !== 'stream') throw new Error('expected a stream part');

    // The declared size is what the multipart encoder sends as Content-Length,
    // and it must be exact or the request is malformed.
    expect(part.size).toBe(400_000);

    let received = 0;
    let biggestChunk = 0;
    for await (const chunk of part.open()) {
      received += chunk.length;
      biggestChunk = Math.max(biggestChunk, chunk.length);
    }

    expect(received).toBe(400_000);
    // The proof: no single chunk was the whole file.
    expect(biggestChunk).toBeLessThan(400_000);
    expect(getCalls).toEqual([GLB_KEY]);
  });

  it('re-opens the source on a retry, because a consumed stream cannot replay', async () => {
    objects.set(GLB_KEY, { size: 1024, contentType: 'model/gltf-binary', etag: '"a"' });

    const result = await assetSyncUploader({
      product: threeDProduct({ usdzUrl: undefined, thumbnailUrl: undefined }),
      slots: ['object'],
      context: context(),
    });
    if (result.outcome !== 'READY') throw new Error('expected READY');
    const part = result.files.object;
    if (!part || part.kind !== 'stream') throw new Error('expected a stream part');

    for await (const _ of part.open()) void _;
    let second = 0;
    for await (const chunk of part.open()) second += chunk.length;

    expect(second).toBe(1024);
    expect(getCalls).toEqual([GLB_KEY, GLB_KEY]);
  });

  it('surfaces an object that vanished between preflight and transfer', async () => {
    objects.set(GLB_KEY, { size: 1024, contentType: 'model/gltf-binary', etag: '"a"' });
    const result = await assetSyncUploader({
      product: threeDProduct({ usdzUrl: undefined, thumbnailUrl: undefined }),
      slots: ['object'],
      context: context(),
    });
    if (result.outcome !== 'READY') throw new Error('expected READY');
    const part = result.files.object;
    if (!part || part.kind !== 'stream') throw new Error('expected a stream part');

    objects.delete(GLB_KEY);

    await expect(
      (async () => {
        for await (const _ of part.open()) void _;
      })()
    ).rejects.toThrow(/disappeared/);
  });
});

describe('transfer — republish', () => {
  it('performs ZERO reads when every asset is unchanged', async () => {
    objects.set(GLB_KEY, { size: 4096, contentType: 'model/gltf-binary', etag: '"a"' });
    objects.set(USDZ_KEY, { size: 512, contentType: 'model/vnd.usdz+zip', etag: '"b"' });
    objects.set(PREVIEW_KEY, { size: 256, contentType: 'image/jpeg', etag: '"c"' });

    const product = threeDProduct({
      publishedSnapshot: {
        assetIdentities: {
          object: { source: cdn(GLB_KEY), etag: '"a"', size: 4096 },
          objectIos: { source: cdn(USDZ_KEY), etag: '"b"', size: 512 },
          image: { source: cdn(PREVIEW_KEY), etag: '"c"', size: 256 },
        },
      },
    });

    const result = await assetSyncUploader({ product, slots: ALL_SLOTS, context: context() });

    expect(result.outcome).toBe('READY');
    if (result.outcome !== 'READY') return;
    expect(Object.keys(result.files)).toHaveLength(0);
    expect(getCalls).toHaveLength(0);
    // The identities are still reported, so the snapshot stays accurate even
    // though nothing moved.
    expect(result.identities.object?.etag).toBe('"a"');
  });

  it('re-pushes only the slot whose bytes changed', async () => {
    objects.set(GLB_KEY, { size: 4096, contentType: 'model/gltf-binary', etag: '"a"' });
    objects.set(PREVIEW_KEY, { size: 256, contentType: 'image/jpeg', etag: '"NEW"' });

    const product = threeDProduct({
      usdzUrl: undefined,
      publishedSnapshot: {
        assetIdentities: {
          object: { source: cdn(GLB_KEY), etag: '"a"', size: 4096 },
          image: { source: cdn(PREVIEW_KEY), etag: '"OLD"', size: 200 },
        },
      },
    });

    const result = await assetSyncUploader({
      product,
      slots: ['object', 'image'],
      context: context(),
    });

    if (result.outcome !== 'READY') throw new Error('expected READY');
    expect(Object.keys(result.files)).toEqual(['image']);
  });

  it('asks for nothing when the step changed no asset field', async () => {
    const result = await assetSyncUploader({
      product: threeDProduct(),
      slots: [],
      context: context(),
    });

    expect(result).toMatchObject({ outcome: 'READY' });
    expect(headCalls).toHaveLength(0);
    expect(getCalls).toHaveLength(0);
  });
});

describe('transfer — URL mode', () => {
  it('sends our CloudFront URLs and reads no bytes', async () => {
    objects.set(GLB_KEY, { size: 4096, contentType: 'model/gltf-binary', etag: '"a"' });
    objects.set(PREVIEW_KEY, { size: 256, contentType: 'image/jpeg', etag: '"c"' });
    vi.spyOn(env, 'MIRAGE_ASSET_TRANSFER_MODE', 'get').mockReturnValue('url');

    const result = await assetSyncUploader({
      product: threeDProduct({ usdzUrl: undefined }),
      slots: ['object', 'image'],
      context: context(),
    });

    if (result.outcome !== 'READY') throw new Error('expected READY');
    expect(result.files).toEqual({});
    expect(result.urls).toEqual({
      objectUrl: cdn(GLB_KEY),
      imageUrl: cdn(PREVIEW_KEY),
    });
    // Preflight still ran — a URL Mirage cannot fetch is worth catching here.
    expect(headCalls).toHaveLength(2);
    expect(getCalls).toHaveLength(0);
  });
});

describe('the USDZ gap', () => {
  it('is logged ONCE per run, not once per product', async () => {
    objects.set(GLB_KEY, { size: 10, contentType: 'model/gltf-binary', etag: '"a"' });
    objects.set(PREVIEW_KEY, { size: 10, contentType: 'image/jpeg', etag: '"c"' });
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});
    const ctx = context();
    const product = threeDProduct({ usdzUrl: undefined });

    await assetSyncUploader({ product, slots: ['object'], context: ctx });
    await assetSyncUploader({ product: { ...product, id: 'p2' }, slots: ['object'], context: ctx });
    await assetSyncUploader({ product: { ...product, id: 'p3' }, slots: ['object'], context: ctx });

    const usdzLines = info.mock.calls.filter(([line]) => String(line).includes('USDZ'));
    expect(usdzLines).toHaveLength(1);
  });

  it('says nothing at all for an image-only product', async () => {
    objects.set(IMAGE_KEY, { size: 10, contentType: 'image/jpeg', etag: '"i"' });
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});

    await assetSyncUploader({
      product: threeDProduct({
        type: 'IMAGE_ONLY',
        glbUrl: undefined,
        usdzUrl: undefined,
        thumbnailUrl: undefined,
        imageKey: IMAGE_KEY,
      }),
      slots: ['image'],
      context: context(),
    });

    expect(info.mock.calls.filter(([line]) => String(line).includes('USDZ'))).toHaveLength(0);
  });
});

describe('no third-party URL can become a fetch', () => {
  it('blocks a product whose model URL is not on our CDN', async () => {
    const result = await preflightAssets(
      threeDProduct({ glbUrl: 'https://assets.meshy.ai/x/model.glb' }),
      ['object'],
      undefined
    );

    expect(result.outcome).toBe('BLOCKED');
    expect(send).not.toHaveBeenCalled();
  });
});
