// src/services/menuPdfService.ts
//
// The printable menu (more-customization Stage 14.4): table tents, a paper menu,
// a PDF for a Zomato listing. Written by hand out of `pdfPrimitives`, like every
// PDF here — deterministic bytes, no library, nothing embedded.
//
// ⚠ BASE-14 FONTS ARE LATIN-ONLY. Helvetica has no ₹ and no Devanagari, so text
// is ASCII-folded (asciiFold) and prices print as "Rs 250". Dishes are printed
// in the menu's PRIMARY language; Hindi/other-script printing would need an
// embedded, shaped font and is not done here.
//
// Headings take the theme's primary colour (Stage 2 presets, or the owner's
// custom primary). The footer on every page carries a QR to the live menu:
// "Scan to see our dishes in 3D".
import { Types } from 'mongoose';

import { DEFAULT_THEME_PRESET_ID, THEME_PRESETS } from '@/config/themePresets';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import {
  A4_HEIGHT_PT,
  A4_WIDTH_PT,
  asciiFold,
  assemblePdf,
  contentStreamObject,
  HELVETICA_BOLD_OBJECT,
  HELVETICA_OBJECT,
  imageXObject,
  matrixFor,
  pdfText,
  proportionalInkWidth,
  qrBitmap1Bit,
} from '@/services/pdfPrimitives';

export const MENU_PDF_TEMPLATES = ['classic', 'compact', 'twoColumn'] as const;
export type MenuPdfTemplate = (typeof MENU_PDF_TEMPLATES)[number];
export const MENU_PDF_SIZES = ['A4', 'A5'] as const;
export type MenuPdfSize = (typeof MENU_PDF_SIZES)[number];

export interface MenuPdfOptions {
  template: MenuPdfTemplate;
  size: MenuPdfSize;
  includeQr: boolean;
  /** `published` (default) prints what customers see; `draft` includes unpublished edits. */
  source: 'published' | 'draft';
}

interface PrintDish {
  name: string;
  description: string;
  price: number | null;
  foodType: string;
  badges: string[];
}

interface PrintSection {
  name: string;
  dishes: PrintDish[];
}

export interface PrintMenu {
  title: string;
  subtitle: string;
  sections: PrintSection[];
  /** Heading colour, `#RRGGBB`. */
  primary: string;
  qrUrl: string | null;
}

const PAGE: Record<MenuPdfSize, { w: number; h: number }> = {
  A4: { w: A4_WIDTH_PT, h: A4_HEIGHT_PT },
  A5: { w: 419.53, h: 595.28 },
};

const clean = (s: string | undefined | null): string =>
  asciiFold((s ?? '').replace(/_/g, ' ').trim());

/** Headings must stay readable on white paper: a very light primary falls back to near-black. */
function printableColour(hex: string): [number, number, number] {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex);
  if (!m) return [0.1, 0.1, 0.1];
  const n = parseInt(m[1], 16);
  const rgb: [number, number, number] = [
    ((n >> 16) & 255) / 255,
    ((n >> 8) & 255) / 255,
    (n & 255) / 255,
  ];
  const luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
  return luminance > 0.75 ? [0.1, 0.1, 0.1] : rgb;
}

const rupees = (p: number): string => `Rs ${Number.isInteger(p) ? p : p.toFixed(2)}`;

// ── Data ───────────────────────────────────────────────────────────────────

export async function loadPrintMenu(
  catalog: ICatalog,
  source: 'published' | 'draft'
): Promise<PrintMenu> {
  const catalogId = catalog._id as Types.ObjectId;
  const [categories, products] = await Promise.all([
    CatalogCategory.find({ catalogId, deletedAt: null }).sort({ position: 1 }).lean().exec(),
    CatalogProduct.find({ catalogId, deletedAt: null, archivedAt: null })
      .sort({ position: 1, _id: 1 })
      .lean()
      .exec(),
  ]);
  const badgeLabel = new Map((catalog.badges ?? []).map((b) => [b.id, b.label]));

  const dishes = products
    .map((p) => {
      const s = source === 'published' ? p.publishedSnapshot : undefined;
      if (source === 'published' && (!p.mirageItemId || !s)) return null;
      return {
        categoryId: String((s ? s.categoryId : p.categoryId) ?? ''),
        dish: {
          name: clean(s?.name ?? p.name),
          description: clean(s?.description ?? p.description),
          price:
            typeof (s ? s.price : p.price) === 'number'
              ? ((s ? s.price : p.price) as number)
              : null,
          foodType: (s?.foodType ?? p.foodType) as string,
          badges: (p.badgeIds ?? [])
            .map((id) => badgeLabel.get(id))
            .filter((l): l is string => Boolean(l))
            .map(clean),
        } satisfies PrintDish,
      };
    })
    .filter((d): d is { categoryId: string; dish: PrintDish } => d !== null);

  const sections: PrintSection[] = categories.map((c) => ({
    name: clean(c.name),
    dishes: dishes.filter((d) => d.categoryId === String(c._id)).map((d) => d.dish),
  }));
  const known = new Set(categories.map((c) => String(c._id)));
  const loose = dishes.filter((d) => !known.has(d.categoryId)).map((d) => d.dish);
  if (loose.length) sections.push({ name: 'More', dishes: loose });

  const a = catalog.appearance;
  const preset =
    THEME_PRESETS.find((p) => p.id === (a?.presetId ?? DEFAULT_THEME_PRESET_ID)) ??
    THEME_PRESETS[0];
  const contact = [catalog.contact?.address, catalog.contact?.phone].filter(Boolean).join('  |  ');
  return {
    title: clean(catalog.businessName || catalog.name),
    subtitle: clean(contact),
    sections: sections.filter((s) => s.dishes.length > 0),
    primary: a?.primary || preset.tokens.primary,
    qrUrl: catalog.publicUrl ?? null,
  };
}

// ── Layout ─────────────────────────────────────────────────────────────────

/** Greedy word wrap to `width` points at `size`. */
export function wrap(text: string, size: number, width: number): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let line = '';
  for (const w of words) {
    const next = line ? `${line} ${w}` : w;
    if (proportionalInkWidth(next, size) <= width || !line) {
      line = next;
    } else {
      lines.push(line);
      line = w;
    }
  }
  if (line) lines.push(line);
  // A single word wider than the column is cut, never allowed to run off the page.
  return lines.map((l) => {
    let cut = l;
    while (proportionalInkWidth(cut, size) > width && cut.length > 1) cut = cut.slice(0, -1);
    return cut;
  });
}

export function renderMenuPdf(menu: PrintMenu, opts: MenuPdfOptions): Buffer {
  const { w, h } = PAGE[opts.size];
  const scale = opts.size === 'A5' ? 0.8 : 1;
  const compact = opts.template === 'compact';
  const columns = opts.template === 'twoColumn' ? 2 : 1;
  const margin = 40 * scale;
  const gutter = 20 * scale;
  const footer = opts.includeQr && menu.qrUrl ? 78 * scale : 24 * scale;
  const colWidth = (w - margin * 2 - gutter * (columns - 1)) / columns;
  const size = {
    title: 26 * scale,
    section: (compact ? 13 : 15) * scale,
    dish: (compact ? 9.5 : 11) * scale,
    desc: (compact ? 8 : 9) * scale,
  };
  const gap = (compact ? 3 : 6) * scale;
  const [pr, pg, pb] = printableColour(menu.primary);
  const colour = `${pr.toFixed(3)} ${pg.toFixed(3)} ${pb.toFixed(3)}`;

  const pages: string[][] = [];
  let ops: string[] = [];
  let col = 0;
  let y = 0;
  const top = () => h - margin;
  const x0 = () => margin + col * (colWidth + gutter);

  const text = (
    font: 'F1' | 'F2',
    sz: number,
    x: number,
    yy: number,
    s: string,
    rgb = '0.1 0.1 0.1'
  ) =>
    ops.push(
      `BT ${rgb} rg /${font} ${sz.toFixed(2)} Tf ${x.toFixed(2)} ${yy.toFixed(2)} Td (${pdfText(s)}) Tj ET`
    );

  const newPage = () => {
    if (ops.length) pages.push(ops);
    ops = [];
    col = 0;
    y = top();
  };
  const ensure = (needed: number) => {
    if (y - needed >= margin + footer) return;
    if (col < columns - 1) {
      col += 1;
      y = pages.length === 0 && ops.length && headerBottom !== null ? headerBottom : top();
      if (y - needed >= margin + footer) return;
    }
    newPage();
  };

  // ── First page header ──
  newPage();
  text('F2', size.title, margin, y - size.title, menu.title, colour);
  y -= size.title + 6 * scale;
  if (menu.subtitle) {
    for (const line of wrap(menu.subtitle, 9 * scale, w - margin * 2)) {
      text('F1', 9 * scale, margin, y - 9 * scale, line, '0.4 0.4 0.4');
      y -= 12 * scale;
    }
  }
  ops.push(
    `${colour} RG 1.2 w ${margin.toFixed(2)} ${(y - 4).toFixed(2)} m ${(w - margin).toFixed(2)} ${(y - 4).toFixed(2)} l S`
  );
  y -= 18 * scale;
  const headerBottom: number | null = y;

  if (menu.sections.length === 0) {
    text('F1', 12 * scale, margin, y - 12 * scale, 'This menu has no dishes yet.', '0.4 0.4 0.4');
  }

  for (const section of menu.sections) {
    ensure(size.section + size.dish * 3);
    y -= size.section;
    text('F2', size.section, x0(), y, section.name.toUpperCase(), colour);
    y -= 4 * scale;
    ops.push(
      `${colour} RG 0.6 w ${x0().toFixed(2)} ${y.toFixed(2)} m ${(x0() + colWidth).toFixed(2)} ${y.toFixed(2)} l S`
    );
    y -= gap + 4 * scale;

    for (const dish of section.dishes) {
      const priceText = dish.price !== null ? rupees(dish.price) : '';
      const priceWidth = priceText ? proportionalInkWidth(priceText, size.dish) + 6 : 0;
      const mark = dish.foodType === 'VEG' || dish.foodType === 'NON_VEG' ? size.dish * 0.9 : 0;
      const nameLines = wrap(dish.name, size.dish, colWidth - priceWidth - (mark ? mark + 5 : 0));
      const badge = dish.badges.length ? `(${dish.badges.join(', ')})` : '';
      const descLines = [
        ...(dish.description ? wrap(dish.description, size.desc, colWidth - 8) : []),
        ...(badge ? wrap(badge, size.desc, colWidth - 8) : []),
      ].slice(0, compact ? 2 : 4);
      const needed = nameLines.length * (size.dish + 2) + descLines.length * (size.desc + 2) + gap;
      ensure(needed);

      const x = x0();
      y -= size.dish;
      if (mark) {
        // Indian veg / non-veg mark: an outlined square with a filled dot.
        const rgb = dish.foodType === 'VEG' ? '0.12 0.55 0.2' : '0.75 0.1 0.1';
        const my = y - 1;
        ops.push(
          `${rgb} RG 0.8 w ${x.toFixed(2)} ${my.toFixed(2)} ${mark.toFixed(2)} ${mark.toFixed(2)} re S`
        );
        const d = mark * 0.45;
        ops.push(
          `${rgb} rg ${(x + (mark - d) / 2).toFixed(2)} ${(my + (mark - d) / 2).toFixed(2)} ${d.toFixed(2)} ${d.toFixed(2)} re f`
        );
      }
      const nx = x + (mark ? mark + 5 : 0);
      const firstLineY = y;
      nameLines.forEach((line, i) => {
        if (i > 0) y -= size.dish + 2;
        text('F2', size.dish, nx, y, line);
      });
      if (priceText) {
        text(
          'F2',
          size.dish,
          x + colWidth - proportionalInkWidth(priceText, size.dish),
          firstLineY,
          priceText,
          colour
        );
      }
      for (const line of descLines) {
        y -= size.desc + 2;
        text('F1', size.desc, nx, y, line, '0.35 0.35 0.35');
      }
      y -= gap + 2;
    }
    y -= gap * 2;
  }
  pages.push(ops);

  // ── Footer + objects ──
  // 1 catalog, 2 pages, 3 Helvetica, 4 Helvetica-Bold, 5 QR image (optional), then page/content pairs.
  const objects: Buffer[] = [];
  const withQr = opts.includeQr && menu.qrUrl;
  const qrObj = 5;
  const firstPageObj = withQr ? 6 : 5;
  const kids = pages.map((_, i) => `${firstPageObj + i * 2} 0 R`).join(' ');
  objects.push(Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'));
  objects.push(Buffer.from(`<< /Type /Pages /Kids [${kids}] /Count ${pages.length} >>`));
  objects.push(Buffer.from(HELVETICA_OBJECT));
  objects.push(Buffer.from(HELVETICA_BOLD_OBJECT));
  if (withQr) objects.push(imageXObject(qrBitmap1Bit(matrixFor(menu.qrUrl!), 4)));

  const qrSide = 58 * scale;
  pages.forEach((pageOps, i) => {
    const footerOps: string[] = [];
    if (withQr) {
      const qx = w - margin - qrSide;
      const qy = margin - 12 * scale;
      footerOps.push(
        `q ${qrSide.toFixed(2)} 0 0 ${qrSide.toFixed(2)} ${qx.toFixed(2)} ${qy.toFixed(2)} cm /Im1 Do Q`
      );
      footerOps.push(
        `BT ${colour} rg /F2 ${(9 * scale).toFixed(2)} Tf ${margin.toFixed(2)} ${(qy + qrSide / 2 + 2).toFixed(2)} Td (${pdfText('Scan to see our dishes in 3D')}) Tj ET`
      );
    }
    if (pages.length > 1) {
      footerOps.push(
        `BT 0.5 0.5 0.5 rg /F1 ${(8 * scale).toFixed(2)} Tf ${margin.toFixed(2)} ${(margin - 20 * scale).toFixed(2)} Td (${pdfText(`${i + 1} / ${pages.length}`)}) Tj ET`
      );
    }
    objects.push(
      Buffer.from(
        `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] ` +
          `/Resources << /Font << /F1 3 0 R /F2 4 0 R >>${withQr ? ` /XObject << /Im1 ${qrObj} 0 R >>` : ''} >> ` +
          `/Contents ${firstPageObj + i * 2 + 1} 0 R >>`
      )
    );
    objects.push(contentStreamObject([...pageOps, ...footerOps].join('\n')));
  });
  return assemblePdf(objects);
}

export async function buildMenuPdf(
  catalogId: Types.ObjectId,
  opts: MenuPdfOptions
): Promise<Buffer | null> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null }).exec();
  if (!catalog) return null;
  return renderMenuPdf(await loadPrintMenu(catalog, opts.source), opts);
}
