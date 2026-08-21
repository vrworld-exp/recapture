// tests/fixtures/mirageFake.ts
//
// An in-memory Mirage that behaves like the real one — the substitute every
// publish test drives through `setMirageClient`.
//
// IT IS DELIBERATELY UNFORGIVING. A fake that happily accepts anything proves
// nothing about code whose entire job is surviving Mirage's quirks, so this one
// reproduces the behaviours that actually break publishing:
//
//   • per-RESTAURANT item-name uniqueness, refused with the message quoted
//     verbatim from adminController.js:1090-1093 — and WITHOUT the existing id,
//     which is what makes reconciliation necessary at all;
//   • per-(restaurant, name) category uniqueness, checked against the RAW
//     request name and only then normalised (adminController.js:724-739) — the
//     ordering bug categorySync compensates for by normalising on our side;
//   • create-item's refusal of a product with neither an image nor a model
//     (adminController.js:1060-1066);
//   • the last-item CATEGORY CASCADE on delete, and `?keepCategory=true`
//     (adminController.js:1651-1690);
//   • `imgOnly` DERIVED on both writes, never taken from the caller;
//   • HTTP 400 for validation AND not-found AND unknown paths.
//
// Every refusal goes through the production classifier
// (`classifyMirageFailure`), so a test failure here is a real classification
// failure and not an artefact of the fake inventing its own error shapes.
import { Types } from 'mongoose';

import { classifyMirageFailure } from '@/services/mirage/mirageErrors';
import type {
  CreateCategoryInput,
  CreateItemInput,
  CreateRestaurantInput,
  DeleteItemOptions,
  DeleteItemResult,
  MirageAnalyticsQuery,
  MirageAnalyticsSummary,
  MirageCategory,
  MirageClient,
  MirageItem,
  MiragePublicCatalog,
  MirageRestaurant,
  MirageTimeseriesPoint,
  MirageTopProductRow,
  UpdateCategoryInput,
  UpdateItemInput,
  UpdateRestaurantInput,
} from '@/services/mirage';

const oid = (): string => new Types.ObjectId().toHexString();

/** Mirage's own normalisation (helper.js:2 + adminController.js:738-739). */
const mirageName = (name: string): string => name.trim().toLowerCase().replace(/ /g, '_');

/** Every write and read the code under test performed, in order. */
export interface MirageCall {
  method: string;
  /** The entity id the call targeted, where there is one. */
  id?: string;
  /** True for anything that mutates Mirage. */
  write: boolean;
}

interface FakeRestaurant {
  id: string;
  name: string;
  location: string;
  phone?: string;
  icon?: string;
  isPublished?: boolean;
  categoryIds: string[];
}

interface FakeCategory {
  id: string;
  name: string;
  restaurantId: string;
  sortPosition?: number;
}

interface FakeItem {
  id: string;
  name: string;
  description?: string;
  price?: number;
  image?: string;
  modelSrc?: string;
  modelIosSrc?: string;
  categoryId: string;
  restaurantId: string;
  imgOnly: boolean;
  sortPosition?: number;
}

/** A scripted failure: the next call to [method] throws this Mirage response. */
export interface ScriptedFailure {
  method: keyof MirageClient;
  status: number;
  message: string;
  /** Fire only once (the default), or on every subsequent call. */
  once?: boolean;
}

export class FakeMirage implements MirageClient {
  readonly restaurants = new Map<string, FakeRestaurant>();
  readonly categories = new Map<string, FakeCategory>();
  readonly items = new Map<string, FakeItem>();
  readonly calls: MirageCall[] = [];

  private failures: ScriptedFailure[] = [];

  /** Makes the next (or every) call to a method fail as Mirage would. */
  failNext(failure: ScriptedFailure): void {
    this.failures.push({ once: true, ...failure });
  }

  /** Every mutating call so far — the "zero writes on a no-op republish" probe. */
  get writes(): MirageCall[] {
    return this.calls.filter((call) => call.write);
  }

  callsTo(method: keyof MirageClient): MirageCall[] {
    return this.calls.filter((call) => call.method === method);
  }

  reset(): void {
    this.restaurants.clear();
    this.categories.clear();
    this.items.clear();
    this.calls.length = 0;
    this.failures = [];
  }

  /** Seeds a restaurant without going through the create path. */
  seedRestaurant(name: string, id = oid()): FakeRestaurant {
    const restaurant: FakeRestaurant = { id, name, location: '', categoryIds: [] };
    this.restaurants.set(id, restaurant);
    return restaurant;
  }

  private record(method: keyof MirageClient, write: boolean, id?: string): void {
    this.calls.push({ method, write, ...(id ? { id } : {}) });
    const index = this.failures.findIndex((failure) => failure.method === method);
    if (index === -1) return;
    const failure = this.failures[index];
    if (failure.once) this.failures.splice(index, 1);
    throw classifyMirageFailure(failure.status, failure.message, method);
  }

  /** Mirage's own refusal shape, routed through the production classifier. */
  private refuse(status: number, message: string, context: string): never {
    throw classifyMirageFailure(status, message, context);
  }

  // ── Restaurants ───────────────────────────────────────────────────────────

  async listRestaurants(): Promise<MirageRestaurant[]> {
    this.record('listRestaurants', false);
    return [...this.restaurants.values()].map((r) => this.toRestaurant(r));
  }

  async createRestaurant(input: CreateRestaurantInput): Promise<MirageRestaurant> {
    this.record('createRestaurant', true);
    // adminController.js:276-289 — an UNANCHORED case-insensitive containment
    // match, not an equality one.
    const collides = [...this.restaurants.values()].some((r) =>
      r.name.toLowerCase().includes(input.name.trim().toLowerCase())
    );
    if (collides) {
      this.refuse(400, 'Restaurant already exist. Name should be unique', 'create restaurant');
    }
    const created: FakeRestaurant = {
      id: oid(),
      name: input.name,
      location: input.location,
      ...(input.phoneNo ? { phone: `+91${input.phoneNo}` } : {}),
      ...(input.image ? { icon: 'https://cdn.mirage.test/icon.jpg' } : {}),
      ...(input.isPublished !== undefined ? { isPublished: input.isPublished } : {}),
      categoryIds: [],
    };
    this.restaurants.set(created.id, created);
    return this.toRestaurant(created);
  }

  async updateRestaurant(id: string, input: UpdateRestaurantInput): Promise<MirageRestaurant> {
    this.record('updateRestaurant', true, id);
    const found = this.restaurants.get(id);
    if (!found) this.refuse(400, 'Restaurant not found', 'update restaurant');
    if (input.name !== undefined) found.name = input.name;
    if (input.location !== undefined) found.location = input.location;
    if (input.phoneNo !== undefined) found.phone = `+91${input.phoneNo}`;
    if (input.isPublished !== undefined) found.isPublished = input.isPublished;
    return this.toRestaurant(found);
  }

  async deleteRestaurant(id: string): Promise<void> {
    this.record('deleteRestaurant', true, id);
    this.restaurants.delete(id);
  }

  // ── Categories ────────────────────────────────────────────────────────────

  async listCategories(restaurantRef: string): Promise<MirageCategory[]> {
    this.record('listCategories', false, restaurantRef);
    return [...this.categories.values()]
      .filter((c) => c.restaurantId === restaurantRef)
      .map((c) => this.toCategory(c));
  }

  async createCategory(input: CreateCategoryInput): Promise<MirageCategory> {
    this.record('createCategory', true);
    const restaurant = this.restaurants.get(input.restaurantId);
    if (!restaurant) this.refuse(400, 'No restaurant found with given id', 'create category');

    // ⚠ The RAW name is what Mirage compares (adminController.js:724-731); the
    // normalisation at :738-739 happens afterwards. A caller that does not
    // pre-normalise slips a duplicate straight past this check.
    const duplicate = [...this.categories.values()].some(
      (c) => c.restaurantId === input.restaurantId && c.name === input.name
    );
    if (duplicate) {
      this.refuse(
        400,
        'Category already exist.Category name should be unique',
        'create category'
      );
    }

    const created: FakeCategory = {
      id: oid(),
      name: mirageName(input.name),
      restaurantId: input.restaurantId,
      ...(input.sortPosition !== undefined ? { sortPosition: input.sortPosition } : {}),
    };
    this.categories.set(created.id, created);
    restaurant.categoryIds.push(created.id);
    return this.toCategory(created);
  }

  async updateCategory(id: string, input: UpdateCategoryInput): Promise<MirageCategory> {
    this.record('updateCategory', true, id);
    const found = this.categories.get(id);
    // adminController.js:871-877 — one of the few routes that answers 404.
    if (!found) this.refuse(404, 'Category not found', 'update category');
    if (input.name !== undefined) found.name = mirageName(input.name);
    if (input.sortPosition !== undefined) found.sortPosition = input.sortPosition;
    return this.toCategory(found);
  }

  // ── Items ─────────────────────────────────────────────────────────────────

  async listItemsForCategory(categoryRef: string): Promise<MirageItem[]> {
    this.record('listItemsForCategory', false, categoryRef);
    return [...this.items.values()]
      .filter((i) => i.categoryId === categoryRef)
      .map((i) => this.toItem(i));
  }

  async createItem(input: CreateItemInput): Promise<MirageItem> {
    this.record('createItem', true);

    if (!input.image && !input.object) {
      this.refuse(400, '3d object and Image are not given.', 'create item');
    }
    if (!this.categories.has(input.categoryId)) {
      this.refuse(400, 'Category not found', 'create item');
    }
    if (!this.restaurants.has(input.restaurantId)) {
      this.refuse(400, 'Restaurant not found', 'create item');
    }
    // Per-RESTAURANT, not per-category (adminController.js:1084-1087). This is
    // why reconciliation scoped to one category can legitimately miss.
    const duplicate = [...this.items.values()].some(
      (i) => i.restaurantId === input.restaurantId && i.name === input.name
    );
    if (duplicate) {
      this.refuse(400, 'Product already exist.Product name should be unique', 'create item');
    }

    const image = input.image ? `https://cdn.mirage.test/imgs/${input.name}.jpg` : undefined;
    const modelSrc = input.object ? `https://cdn.mirage.test/models/${input.name}.glb` : undefined;
    const created: FakeItem = {
      id: oid(),
      name: input.name,
      ...(input.description !== undefined ? { description: input.description } : {}),
      ...(input.price && input.price > 0 ? { price: input.price } : {}),
      ...(image ? { image } : {}),
      ...(modelSrc ? { modelSrc } : {}),
      ...(input.objectIos
        ? { modelIosSrc: `https://cdn.mirage.test/models/${input.name}.usdz` }
        : {}),
      categoryId: input.categoryId,
      restaurantId: input.restaurantId,
      // DERIVED, never taken from the caller (adminController.js:1192-1194).
      imgOnly: Boolean(image) && !modelSrc,
      ...(input.sortPosition !== undefined ? { sortPosition: input.sortPosition } : {}),
    };
    this.items.set(created.id, created);
    return this.toItem(created);
  }

  async updateItem(id: string, input: UpdateItemInput): Promise<MirageItem> {
    this.record('updateItem', true, id);
    const found = this.items.get(id);
    if (!found) {
      this.refuse(404, `Product not found with given productId`, 'update item');
    }

    if (input.name && input.name !== found.name) {
      const duplicate = [...this.items.values()].some(
        (i) => i.id !== id && i.restaurantId === found.restaurantId && i.name === input.name
      );
      if (duplicate) {
        this.refuse(400, 'Product already exist.Product name should be unique', 'update item');
      }
      found.name = input.name;
    }

    if (input.categoryId !== undefined && input.categoryId !== found.categoryId) {
      const target = this.categories.get(input.categoryId);
      if (!target) this.refuse(400, 'Category not found', 'update item');
      if (target.restaurantId !== found.restaurantId) {
        this.refuse(400, "Category does not belong to this product's restaurant", 'update item');
      }
      found.categoryId = target.id;
    }

    // `if (price && …)` — a price cannot be cleared or zeroed here.
    if (input.price) found.price = input.price;
    if (input.description !== undefined) found.description = input.description;
    if (input.sortPosition !== undefined) found.sortPosition = input.sortPosition;
    if (input.image) found.image = `https://cdn.mirage.test/imgs/${found.name}.jpg`;
    if (input.object) found.modelSrc = `https://cdn.mirage.test/models/${found.name}.glb`;
    if (input.objectIos) {
      found.modelIosSrc = `https://cdn.mirage.test/models/${found.name}.usdz`;
    }
    found.imgOnly = Boolean(found.image) && !found.modelSrc;
    return this.toItem(found);
  }

  async deleteItem(id: string, options: DeleteItemOptions = {}): Promise<DeleteItemResult> {
    this.record('deleteItem', true, id);
    const found = this.items.get(id);
    // This fake stands in for the CLIENT, not the transport, and the client's
    // contract is that Mirage's 404 for a missing item resolves to
    // `{existed:false}` — a replayed delete has to converge, not fail
    // (mirageClient.deleteItem).
    if (!found) return { existed: false, deletedCategory: false };

    let deletedCategory = false;
    const siblings = [...this.items.values()].filter((i) => i.categoryId === found.categoryId);
    if (!options.keepCategory && siblings.length === 1) {
      this.categories.delete(found.categoryId);
      const restaurant = this.restaurants.get(found.restaurantId);
      if (restaurant) {
        restaurant.categoryIds = restaurant.categoryIds.filter((c) => c !== found.categoryId);
      }
      deletedCategory = true;
    }

    this.items.delete(id);
    return { existed: true, deletedCategory };
  }

  // ── Reads nothing in B2 exercises, present to satisfy the interface ───────

  async getPublicCatalog(slug: string): Promise<MiragePublicCatalog> {
    this.record('getPublicCatalog', false, slug);
    const restaurant = this.restaurants.get(slug);
    if (!restaurant) this.refuse(400, 'Invalid restaurant name or id', 'read public catalog');
    return {
      restaurant: { id: restaurant.id, name: restaurant.name, location: restaurant.location },
      categories: [...this.categories.values()]
        .filter((c) => c.restaurantId === restaurant.id)
        .map((c) => this.toCategory(c)),
      items: [...this.items.values()]
        .filter((i) => i.restaurantId === restaurant.id)
        .map((i) => this.toItem(i)),
    };
  }

  async analyticsSummary(query: MirageAnalyticsQuery): Promise<MirageAnalyticsSummary> {
    this.record('analyticsSummary', false, query.restaurantId);
    return {
      range: { from: query.from ?? '', to: query.to ?? '' },
      kpis: {
        pageViews: 0,
        sessions: 0,
        visitors: 0,
        productViews: 0,
        arViews: 0,
        arSessions: 0,
        contactClicks: 0,
        searches: 0,
      },
    };
  }

  async analyticsTimeseries(query: MirageAnalyticsQuery): Promise<MirageTimeseriesPoint[]> {
    this.record('analyticsTimeseries', false, query.restaurantId);
    return [];
  }

  async analyticsTopProducts(query: MirageAnalyticsQuery): Promise<MirageTopProductRow[]> {
    this.record('analyticsTopProducts', false, query.restaurantId);
    return [];
  }

  // ── Normalisers ───────────────────────────────────────────────────────────

  private toRestaurant(r: FakeRestaurant): MirageRestaurant {
    return {
      id: r.id,
      name: r.name,
      location: r.location,
      ...(r.phone ? { phone: r.phone } : {}),
      ...(r.icon ? { icon: r.icon } : {}),
      ...(r.isPublished !== undefined ? { isPublished: r.isPublished } : {}),
      categoryIds: [...r.categoryIds],
    };
  }

  private toCategory(c: FakeCategory): MirageCategory {
    return {
      id: c.id,
      name: c.name,
      restaurantId: c.restaurantId,
      ...(c.sortPosition !== undefined ? { sortPosition: c.sortPosition } : {}),
      productIds: [...this.items.values()].filter((i) => i.categoryId === c.id).map((i) => i.id),
    };
  }

  private toItem(i: FakeItem): MirageItem {
    return {
      id: i.id,
      name: i.name,
      ...(i.description !== undefined ? { description: i.description } : {}),
      ...(i.price !== undefined ? { price: i.price } : {}),
      ...(i.image ? { image: i.image } : {}),
      ...(i.modelSrc ? { modelSrc: i.modelSrc } : {}),
      ...(i.modelIosSrc ? { modelIosSrc: i.modelIosSrc } : {}),
      categoryId: i.categoryId,
      restaurantId: i.restaurantId,
      imgOnly: i.imgOnly,
      ...(i.sortPosition !== undefined ? { sortPosition: i.sortPosition } : {}),
    };
  }
}
