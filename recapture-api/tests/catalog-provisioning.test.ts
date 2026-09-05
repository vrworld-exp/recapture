// tests/catalog-provisioning.test.ts
//
// Provisioning, the mapping, and the frozen public URL (T-024 / features 40-42).
//
// WHAT THIS SUITE IS PROTECTING: `publicUrl` is the string a business PRINTS.
// Once a sticker exists, a rewrite is not a bug that can be fixed forward — the
// customer scanning it lands nowhere. So the properties pinned here are the
// irreversible ones:
//
//   • the URL is minted from the Mirage restaurant's immutable `_id`, ONCE;
//   • a rename, a republish, product churn and a second provisioning attempt all
//     leave it byte-identical (feature 32, the brief's hard constraint);
//   • a catalog that already has a mapping makes NO Mirage call at all, because
//     the publish processor calls provision() at the top of every run;
//   • two catalogs can never end up pointing at the same Mirage restaurant,
//     which is the multi-tenancy hazard hiding inside "adopt by name".
//
// Hermetic: in-memory Mongo, an injected Mirage client, a scripted S3. CI never
// touches Mirage — which shares a database with production.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { GetObjectCommand } from '@aws-sdk/client-s3';

import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Catalog } from '@/models/Catalog';
import type { PublicUrlScheme } from '@/models/types/catalog.types';
import {
  MirageError,
  MirageErrorCode,
  resetMirageClient,
  setMirageClient,
  type MirageClient,
  type MirageRestaurant,
} from '@/services/mirage';
import {
  provisionCatalog,
  suggestAvailableName,
  syncCatalogBranding,
} from '@/services/catalogProvisioningService';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The unique partial index on mirageRestaurantId is the multi-tenancy rule —
  // without syncIndexes it would not exist and the test asserting it would pass
  // for the wrong reason.
  await Catalog.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  // Every MIRAGE_* key is optional by schema so an API that never publishes
  // still boots; the suite supplies them here (the same shape as
  // tests/mirage-error-classification.test.ts) rather than in vitest.config.ts.
  Object.assign(env, {
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
  });
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  await Catalog.deleteMany({});
});

// ── Fakes ───────────────────────────────────────────────────────────────────

interface FakeMirage {
  client: MirageClient;
  restaurants: MirageRestaurant[];
  calls: string[];
  /** Thrown by the next createRestaurant call, once. */
  createThrows?: Error;
  /** Thrown by the next updateRestaurant call, once. */
  updateThrows?: Error;
  /** The multipart file the last write carried, if any. */
  lastImage?: { filename: string; contentType: string; byteLength: number };
}

/**
 * A Mirage stand-in for the three endpoints provisioning uses.
 *
 * `createRestaurant` reproduces the behaviour that shapes this whole service:
 * Mirage's uniqueness check is an UNANCHORED case-insensitive regex
 * (adminController.js:276-282), so an existing "Blue Cafe House" refuses a new
 * "Cafe". Every other method throws — reaching one would mean provisioning grew
 * a call it has no business making.
 */
function fakeMirage(seed: MirageRestaurant[] = []): FakeMirage {
  const state: FakeMirage = {
    restaurants: [...seed],
    calls: [],
    client: undefined as unknown as MirageClient,
  };

  const unexpected = (name: string) => async () => {
    throw new Error(`provisioning must not call ${name}`);
  };

  state.client = {
    listRestaurants: async () => {
      state.calls.push('listRestaurants');
      return state.restaurants.map((r) => ({ ...r }));
    },
    createRestaurant: async (input) => {
      state.calls.push('createRestaurant');
      if (input.image) {
        state.lastImage = {
          filename: input.image.filename,
          contentType: input.image.contentType,
          byteLength: input.image.bytes.byteLength,
        };
      }
      if (state.createThrows) {
        const err = state.createThrows;
        state.createThrows = undefined;
        throw err;
      }
      const taken = state.restaurants.some((r) =>
        r.name.toLowerCase().includes(input.name.toLowerCase())
      );
      if (taken) {
        throw new MirageError(
          MirageErrorCode.ALREADY_EXISTS,
          'reconcile',
          'That name is already in use on Mirage.',
          'create restaurant',
          400,
          'Restaurant already exist. Name should be unique'
        );
      }
      const created: MirageRestaurant = {
        id: new Types.ObjectId().toHexString(),
        name: input.name,
        location: input.location,
        ...(input.phoneNo ? { phone: `+91${input.phoneNo}` } : {}),
        website: input.website ?? '',
        socialLinks: { ...input.socialLinks },
        categoryIds: [],
      };
      state.restaurants.push(created);
      return { ...created };
    },
    updateRestaurant: async (id, input) => {
      state.calls.push('updateRestaurant');
      if (input.image) {
        state.lastImage = {
          filename: input.image.filename,
          contentType: input.image.contentType,
          byteLength: input.image.bytes.byteLength,
        };
      }
      if (state.updateThrows) {
        const err = state.updateThrows;
        state.updateThrows = undefined;
        throw err;
      }
      const found = state.restaurants.find((r) => r.id === id);
      if (!found) throw new Error(`no such restaurant ${id}`);
      found.name = input.name;
      found.location = input.location;
      if (input.website !== undefined) found.website = input.website;
      // Mirage MERGES this object key by key (adminController.js:685-689) rather
      // than replacing it. Reproducing that here is what makes the "a cleared
      // handle actually disappears" test mean anything.
      if (input.socialLinks !== undefined) {
        found.socialLinks = { ...found.socialLinks, ...input.socialLinks };
      }
      return { ...found };
    },
    deleteRestaurant: unexpected('deleteRestaurant'),
    listCategories: unexpected('listCategories'),
    createCategory: unexpected('createCategory'),
    updateCategory: unexpected('updateCategory'),
    listItemsForCategory: unexpected('listItemsForCategory'),
    createItem: unexpected('createItem'),
    updateItem: unexpected('updateItem'),
    deleteItem: unexpected('deleteItem'),
    getPublicCatalog: unexpected('getPublicCatalog'),
    analyticsSummary: unexpected('analyticsSummary'),
    analyticsTimeseries: unexpected('analyticsTimeseries'),
    analyticsTopProducts: unexpected('analyticsTopProducts'),
  } as MirageClient;

  setMirageClient(state.client);
  return state;
}

function restaurant(name: string): MirageRestaurant {
  return {
    id: new Types.ObjectId().toHexString(),
    name,
    location: '',
    categoryIds: [],
  };
}

/** A catalog owned by a fresh user. Only provisioning-relevant fields matter. */
async function seedCatalog(
  overrides: Partial<{
    name: string;
    contact: {
      phone?: string;
      address?: string;
      website?: string;
      socials?: {
        instagram?: string;
        facebook?: string;
        youtube?: string;
        whatsapp?: string;
      };
    };
    logoKey: string;
    /** Pre-set by rep activation — see the RECAPTURE_SHORT_CODE tests below. */
    publicUrl: string;
    publicUrlScheme: PublicUrlScheme;
  }> = {}
): Promise<{ id: Types.ObjectId; name: string }> {
  const doc = await Catalog.create({
    userId: new Types.ObjectId(),
    name: overrides.name ?? 'Blue Cafe',
    ...(overrides.contact ? { contact: overrides.contact } : {}),
    ...(overrides.logoKey ? { logoKey: overrides.logoKey } : {}),
    ...(overrides.publicUrl ? { publicUrl: overrides.publicUrl } : {}),
    ...(overrides.publicUrlScheme ? { publicUrlScheme: overrides.publicUrlScheme } : {}),
  });
  return { id: doc._id as Types.ObjectId, name: doc.name };
}

/** Scripts S3 so exactly [keys] exist, each holding [bytes] bytes. */
function stubS3(objects: Record<string, number>): void {
  vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
    if (command instanceof GetObjectCommand) {
      const key = command.input.Key as string;
      const size = objects[key];
      if (size === undefined) {
        const err = new Error('NoSuchKey');
        err.name = 'NoSuchKey';
        return Promise.reject(err);
      }
      return Promise.resolve({
        ContentType: 'application/octet-stream',
        Body: { transformToByteArray: async () => new Uint8Array(size) },
      }) as never;
    }
    throw new Error('unexpected S3 command');
  });
}

// ── Minting and freezing ────────────────────────────────────────────────────

describe('provisionCatalog — minting the public URL', () => {
  it('creates the restaurant and mints {MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ name: 'Blue Cafe' });

    const result = await provisionCatalog(id);

    expect(result.outcome).toBe('CREATED');
    if (result.outcome !== 'CREATED') return;

    const created = mirage.restaurants[0];
    expect(created).toBeDefined();
    expect(result.mapping.mirageRestaurantId).toBe(created?.id);
    // The ObjectId, not the name: renaming must not be able to move the URL.
    expect(result.mapping.publicUrl).toBe(`https://menu.test/${created?.id}`);
    expect(result.mapping.publicUrlScheme).toBe('MIRAGE_OBJECT_ID');

    const stored = await Catalog.findById(id).exec();
    expect(stored?.publicUrl).toBe(result.mapping.publicUrl);
    expect(stored?.mirageProvisionedAt).toBeInstanceOf(Date);
  });

  it('does not bump draftRevision — provisioning is not an authoring edit', async () => {
    fakeMirage();
    const { id } = await seedCatalog();
    const before = (await Catalog.findById(id).exec())?.draftRevision;

    await provisionCatalog(id);

    expect((await Catalog.findById(id).exec())?.draftRevision).toBe(before);
  });

  it('refuses to mint when MIRAGE_PUBLIC_BASE_URL is absent — before any Mirage call', async () => {
    const mirage = fakeMirage();
    Object.assign(env, { MIRAGE_PUBLIC_BASE_URL: undefined });
    const { id } = await seedCatalog();

    await expect(provisionCatalog(id)).rejects.toMatchObject({
      code: MirageErrorCode.NOT_CONFIGURED,
    });
    expect(mirage.calls).toEqual([]);
    expect((await Catalog.findById(id).exec())?.mirageRestaurantId).toBeUndefined();
  });
});

describe('provisionCatalog — a rep-activated catalog keeps its standee URL', () => {
  it('writes the Mirage mapping without touching a pre-set publicUrl', async () => {
    const mirage = fakeMirage();
    const standeeUrl = 'https://scan.test/r/ABCD2345';
    const { id } = await seedCatalog({
      name: 'Blue Cafe',
      publicUrl: standeeUrl,
      publicUrlScheme: 'RECAPTURE_SHORT_CODE',
    });

    const result = await provisionCatalog(id);

    // Mirage provisioning owns `mirageRestaurantId`. It does NOT own the URL:
    // this catalog's code is already printed on a standee, and minting over it
    // would break every one of them in the field.
    expect(result.outcome).toBe('CREATED');
    const stored = await Catalog.findById(id).exec();
    expect(stored?.mirageRestaurantId).toBe(mirage.restaurants[0]?.id);
    expect(stored?.mirageProvisionedAt).toBeInstanceOf(Date);
    expect(stored?.publicUrl).toBe(standeeUrl);
    expect(stored?.publicUrlScheme).toBe('RECAPTURE_SHORT_CODE');

    // And the mapping the caller is handed reports the URL that is actually
    // stored, not the one that would have been minted.
    if (result.outcome !== 'CREATED') return;
    expect(result.mapping.publicUrl).toBe(standeeUrl);
    expect(result.mapping.publicUrlScheme).toBe('RECAPTURE_SHORT_CODE');
  });

  it('still mints for a catalog with no publicUrl — the unchanged path', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ name: 'Green Cafe' });

    const result = await provisionCatalog(id);

    // The split payload must not have broken the flow every existing catalog
    // goes through.
    const created = mirage.restaurants[0];
    const stored = await Catalog.findById(id).exec();
    expect(stored?.publicUrl).toBe(`https://menu.test/${created?.id}`);
    expect(stored?.publicUrlScheme).toBe('MIRAGE_OBJECT_ID');
    if (result.outcome !== 'CREATED') return;
    expect(result.mapping.publicUrl).toBe(`https://menu.test/${created?.id}`);
  });
});

describe('provisionCatalog — the URL is frozen', () => {
  it('is a no-op with NO Mirage call once the catalog is mapped', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog();

    const first = await provisionCatalog(id);
    expect(first.outcome).toBe('CREATED');
    mirage.calls.length = 0;

    const second = await provisionCatalog(id);

    expect(second.outcome).toBe('ALREADY_PROVISIONED');
    expect(mirage.calls).toEqual([]);
    if (first.outcome !== 'CREATED' || second.outcome !== 'ALREADY_PROVISIONED') return;
    expect(second.mapping.publicUrl).toBe(first.mapping.publicUrl);
  });

  it('survives a rename, a republish and product churn byte-for-byte', async () => {
    fakeMirage();
    const { id } = await seedCatalog({ name: 'Blue Cafe' });

    const first = await provisionCatalog(id);
    if (first.outcome !== 'CREATED') throw new Error('expected CREATED');
    const minted = first.mapping.publicUrl;

    // Everything a business does after printing the sticker.
    await Catalog.updateOne(
      { _id: id },
      {
        $set: { name: 'Blue Cafe & Bakery', status: 'PUBLISHED', publishedRevision: 4 },
        $inc: { draftRevision: 7 },
      }
    ).exec();
    await syncCatalogBranding(id);
    await provisionCatalog(id);

    const stored = await Catalog.findById(id).exec();
    expect(stored?.publicUrl).toBe(minted);
    expect(stored?.mirageRestaurantId).toBe(first.mapping.mirageRestaurantId);
  });

  it('keeps the winner when a concurrent run provisions first', async () => {
    fakeMirage();
    const { id } = await seedCatalog();

    // Two runs race; both go through the same conditional write.
    const [a, b] = await Promise.all([provisionCatalog(id), provisionCatalog(id)]);

    const urls = [a, b].map((r) => ('mapping' in r ? r.mapping.publicUrl : null));
    expect(urls[0]).toBe(urls[1]);
    expect(urls[0]).toBeTruthy();

    const stored = await Catalog.findById(id).exec();
    expect(stored?.publicUrl).toBe(urls[0]);
  });
});

// ── Adoption and name collisions ────────────────────────────────────────────

describe('provisionCatalog — adopting an existing Mirage restaurant', () => {
  it('adopts an exact case-insensitive name match instead of creating', async () => {
    const existing = restaurant('blue cafe');
    const mirage = fakeMirage([existing]);
    const { id } = await seedCatalog({ name: 'Blue Cafe' });

    const result = await provisionCatalog(id);

    expect(result.outcome).toBe('ADOPTED');
    if (result.outcome !== 'ADOPTED') return;
    expect(result.mapping.mirageRestaurantId).toBe(existing.id);
    expect(result.mapping.publicUrl).toBe(`https://menu.test/${existing.id}`);
    expect(mirage.calls).toEqual(['listRestaurants']);
  });

  it('never lets a second catalog adopt a restaurant another one already owns', async () => {
    const shared = restaurant('Blue Cafe');
    fakeMirage([shared]);

    const first = await seedCatalog({ name: 'Blue Cafe' });
    expect((await provisionCatalog(first.id)).outcome).toBe('ADOPTED');

    // A different user, same catalog name. Adopting would publish their products
    // onto the first user's public page.
    const second = await seedCatalog({ name: 'Blue Cafe' });
    const result = await provisionCatalog(second.id);

    expect(result.outcome).toBe('NAME_TAKEN');
    if (result.outcome !== 'NAME_TAKEN') return;
    expect(result.code).toBe('CATALOG_NAME_TAKEN');
    expect(result.suggestedName).not.toBe('Blue Cafe');

    const stored = await Catalog.findById(second.id).exec();
    expect(stored?.mirageRestaurantId).toBeUndefined();
    expect(stored?.publicUrl).toBeUndefined();
  });

  it("reports CATALOG_NAME_TAKEN for Mirage's unanchored containment rule, with a free suggestion", async () => {
    // Mirage refuses "Cafe" while "Blue Cafe House" exists — a substring test.
    const mirage = fakeMirage([restaurant('Blue Cafe House')]);
    const { id } = await seedCatalog({ name: 'Cafe' });

    const result = await provisionCatalog(id);

    expect(result.outcome).toBe('NAME_TAKEN');
    if (result.outcome !== 'NAME_TAKEN') return;
    expect(result.suggestedName).toBe('cafe_2');
    // Refused before the doomed create — one list call, nothing else.
    expect(mirage.calls).toEqual(['listRestaurants']);
  });

  it('adopts rather than duplicating when the name is claimed between list and create', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ name: 'Blue Cafe' });

    // The list comes back empty, then someone else creates the same name.
    const claimed = restaurant('Blue Cafe');
    mirage.createThrows = new MirageError(
      MirageErrorCode.ALREADY_EXISTS,
      'reconcile',
      'That name is already in use on Mirage.',
      'create restaurant',
      400,
      'Restaurant already exist. Name should be unique'
    );
    mirage.restaurants.push(claimed);

    const result = await provisionCatalog(id);

    expect(result.outcome).toBe('ADOPTED');
    if (result.outcome !== 'ADOPTED') return;
    expect(result.mapping.mirageRestaurantId).toBe(claimed.id);
  });
});

describe('suggestAvailableName', () => {
  it('skips every suffix Mirage would still refuse', async () => {
    // Containment is judged on the SLUG of both sides, which is the form Mirage
    // holds: "cafe_2" is contained in "cafe_2_go", so the walk skips to 4.
    expect(suggestAvailableName('Cafe', ['Cafe', 'Cafe 2 Go', 'the cafe 3'], 'abc123')).toBe(
      'cafe_4'
    );
  });

  it('falls back to the catalog-id tail when the numbers are exhausted', async () => {
    const crowded = Array.from({ length: 9 }, (_, i) => `Cafe ${i + 1}`);
    expect(suggestAvailableName('Cafe', crowded, 'abc123')).toBe('cafe_abc123');
  });
});

// ── Branding ────────────────────────────────────────────────────────────────

describe('branding', () => {
  it('always sends name and location, and strips the phone to digits Mirage will accept', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({
      name: 'Blue Cafe',
      // Mirage prefixes +91 itself, so a stored +91 must not go out.
      contact: { phone: '+91 98765 43210', address: '42 Church Street' },
    });

    await provisionCatalog(id);

    const created = mirage.restaurants[0];
    expect(created?.location).toBe('42 Church Street');
    expect(created?.phone).toBe('+919876543210');
  });

  it('sends the logo with a real extension, because Mirage builds its S3 key from it', async () => {
    const key = 'dev/catalog/000000000000000000000abc/products/logo/img-1.png';
    stubS3({ [key]: 128 });
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ logoKey: key });

    await provisionCatalog(id);

    expect(mirage.lastImage).toEqual({
      filename: 'logo.png',
      contentType: 'image/png',
      byteLength: 128,
    });
  });

  it('provisions anyway when the logo object is gone — a missing icon must not cost a QR', async () => {
    stubS3({});
    const mirage = fakeMirage();
    const { id } = await seedCatalog({
      logoKey: 'dev/catalog/000000000000000000000abc/products/logo/img-1.png',
    });

    const result = await provisionCatalog(id);

    expect(result.outcome).toBe('CREATED');
    expect(mirage.lastImage).toBeUndefined();
  });

  it('pushes branding through M3 once provisioned', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ name: 'Blue Cafe' });
    await provisionCatalog(id);

    await Catalog.updateOne({ _id: id }, { $set: { name: 'Blue Cafe & Bakery' } }).exec();
    const result = await syncCatalogBranding(id);

    expect(result.outcome).toBe('SYNCED');
    expect(mirage.restaurants[0]?.name).toBe('Blue Cafe & Bakery');
  });

  it('reports a refused rename without touching the mapping or the URL', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ name: 'Blue Cafe' });
    const provisioned = await provisionCatalog(id);
    if (provisioned.outcome !== 'CREATED') throw new Error('expected CREATED');

    mirage.restaurants.push(restaurant('Green Cafe'));
    await Catalog.updateOne({ _id: id }, { $set: { name: 'Green Cafe' } }).exec();
    mirage.updateThrows = new MirageError(
      MirageErrorCode.ALREADY_EXISTS,
      'reconcile',
      'That name is already in use on Mirage.',
      'update restaurant',
      400,
      'Restaurant already exist with given name. Name should be unique'
    );

    const result = await syncCatalogBranding(id);

    expect(result.outcome).toBe('NAME_TAKEN');
    if (result.outcome !== 'NAME_TAKEN') return;
    expect(result.suggestedName).toBe('green_cafe_2');

    const stored = await Catalog.findById(id).exec();
    expect(stored?.publicUrl).toBe(provisioned.mapping.publicUrl);
    expect(stored?.mirageRestaurantId).toBe(provisioned.mapping.mirageRestaurantId);
  });

  // ── Website and social links (the public contact sheet) ───────────────────
  //
  // Mirage's restaurant schema carries `website` and `socialLinks`, and the
  // public page renders them in the contact sheet a customer opens from the call
  // icon. They are stored on the catalog like any other contact field, so the
  // only thing that can break them is this service forgetting to send them —
  // which is exactly what it used to do.

  it('carries website and social links onto the restaurant at provisioning', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({
      contact: {
        website: 'https://blue.example',
        socials: { instagram: 'blue_cafe', youtube: 'https://youtube.com/@blue' },
      },
    });

    await provisionCatalog(id);

    expect(mirage.restaurants[0]?.website).toBe('https://blue.example');
    expect(mirage.restaurants[0]?.socialLinks).toMatchObject({
      instagram: 'blue_cafe',
      youtube: 'https://youtube.com/@blue',
    });
  });

  it('pushes website and social links on every branding sync', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ name: 'Blue Cafe' });
    await provisionCatalog(id);

    await Catalog.updateOne(
      { _id: id },
      {
        $set: {
          'contact.website': 'blue.example',
          'contact.socials': { instagram: 'blue_cafe', facebook: 'bluecafe' },
        },
      }
    ).exec();

    expect((await syncCatalogBranding(id)).outcome).toBe('SYNCED');
    expect(mirage.restaurants[0]?.website).toBe('blue.example');
    expect(mirage.restaurants[0]?.socialLinks).toMatchObject({
      instagram: 'blue_cafe',
      facebook: 'bluecafe',
    });
  });

  // The reason every key is sent even when empty: Mirage merges this object, so
  // an omitted key would leave a deleted handle live on the public page.
  it('clears a handle the business removed instead of leaving it live', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({
      contact: { website: 'blue.example', socials: { instagram: 'blue_cafe' } },
    });
    await provisionCatalog(id);
    expect(mirage.restaurants[0]?.socialLinks?.instagram).toBe('blue_cafe');

    // The profile screen REPLACES the whole contact block, so removing the
    // handle leaves `socials` absent rather than holding an empty string.
    await Catalog.updateOne({ _id: id }, { $set: { contact: {} } }).exec();
    await syncCatalogBranding(id);

    expect(mirage.restaurants[0]?.socialLinks?.instagram).toBe('');
    expect(mirage.restaurants[0]?.website).toBe('');
  });

  // `x` and `linkedin` have no ReCapture field. Clearing them would delete
  // something only Mirage's own admin UI can set.
  it('leaves the Mirage-only handles alone', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog();
    await provisionCatalog(id);

    mirage.restaurants[0]!.socialLinks = { x: 'blue_cafe', linkedin: 'blue-cafe' };
    await syncCatalogBranding(id);

    expect(mirage.restaurants[0]?.socialLinks).toMatchObject({
      x: 'blue_cafe',
      linkedin: 'blue-cafe',
    });
  });

  // The public page builds `https://wa.me/{value}`, which reads digits only.
  it('normalises the WhatsApp number into something wa.me can resolve', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({
      contact: { socials: { whatsapp: '+91 98765 43210' } },
    });

    await provisionCatalog(id);

    expect(mirage.restaurants[0]?.socialLinks?.whatsapp).toBe('919876543210');
  });

  it('gives a bare 10-digit WhatsApp number its country code', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog({ contact: { socials: { whatsapp: '9876543210' } } });

    await provisionCatalog(id);

    expect(mirage.restaurants[0]?.socialLinks?.whatsapp).toBe('919876543210');
  });

  it('is a no-op on a catalog that has never been provisioned', async () => {
    const mirage = fakeMirage();
    const { id } = await seedCatalog();

    expect((await syncCatalogBranding(id)).outcome).toBe('NOT_PROVISIONED');
    expect(mirage.calls).toEqual([]);
  });
});
