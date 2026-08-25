// src/modules/asset-pipeline/cli.ts
//
//   npm run pipeline -- --input ./samples/dish.glb --profile food
//
// Runs the full recipe against a local GLB and writes the outputs beside it.
// Makes NO AWS calls and opens NO database connection — it imports the pure
// library only, never publish.ts. That is the point: tuning a texture budget
// against a real Meshy sample should not need credentials, a queue, or a
// deployed environment.
//
// Exits non-zero when a hard gate fails, so it is usable in a check script.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

import { DEFAULT_PROFILE_NAME, largestTexture, listProfileNames, runPipeline } from './index';
import type { InspectionReport } from './types';

interface CliArgs {
  input: string;
  profile: string;
  outDir?: string;
  quiet: boolean;
}

function parseArgs(argv: string[]): CliArgs {
  const args: Record<string, string | boolean> = {};
  const positional: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith('--')) {
      positional.push(token);
      continue;
    }

    // Both `--input path` and `--input=path` are accepted. The `=` form is not
    // a nicety: on Windows, `npm run pipeline -- --input ./x.glb` has npm eat
    // `--input` as its own config and hand the script a bare path, so `=` is
    // the form that reliably survives the npm wrapper there.
    const body = token.slice(2);
    const eq = body.indexOf('=');
    if (eq !== -1) {
      args[body.slice(0, eq)] = body.slice(eq + 1);
      continue;
    }

    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      args[body] = next;
      i++;
    } else {
      args[body] = true;
    }
  }

  // Positional fallback: `npm run pipeline -- ./samples/dish.glb food`.
  // npm (at least through v10 on Windows) claims `--input`/`--profile` as its
  // OWN config and never forwards them, so the flag form only survives when the
  // script is invoked directly (npx tsx …). Positional args always get through,
  // which makes them the form that works everywhere.
  const input = typeof args.input === 'string' ? args.input : positional[0];
  if (!input) {
    throw new Error(
      'Usage:\n' +
        '  npm run pipeline -- ./samples/dish.glb [food]\n' +
        '  npx tsx src/modules/asset-pipeline/cli.ts --input ./samples/dish.glb --profile food\n' +
        '  (npm swallows --input/--profile; use the positional form with npm)'
    );
  }

  return {
    input,
    profile:
      typeof args.profile === 'string' ? args.profile : (positional[1] ?? DEFAULT_PROFILE_NAME),
    ...(typeof args.out === 'string' ? { outDir: args.out } : {}),
    quiet: args.quiet === true,
  };
}

/** The before/after table — the same numbers the worker logs. */
function printTable(before: InspectionReport, after: InspectionReport | undefined): void {
  const row = (r: InspectionReport) => ({
    'size (MB)': (r.totalBytes / 1e6).toFixed(2),
    triangles: r.triangles,
    textures: r.textureCount,
    'largest texture (KB)': Math.round(largestTexture(r) / 1e3),
    'draw calls': r.drawCallEstimate,
    'longest dim (m)': r.boundingBox.longestDimMeters.toFixed(3),
  });

  const rows: Record<string, ReturnType<typeof row>> = { before: row(before) };
  if (after) rows.after = row(after);
  console.table(rows);

  if (after) {
    const pct = ((1 - after.totalBytes / Math.max(1, before.totalBytes)) * 100).toFixed(1);
    console.log(`\n  ${pct}% smaller — ${mb(before.totalBytes)} MB → ${mb(after.totalBytes)} MB\n`);
  }
}

function mb(bytes: number): string {
  return (bytes / 1e6).toFixed(2);
}

async function main(): Promise<number> {
  const args = parseArgs(process.argv.slice(2));
  const inputPath = resolve(args.input);
  const outDir = resolve(args.outDir ?? join(dirname(inputPath), 'out'));
  mkdirSync(outDir, { recursive: true });

  console.log(`\n  input   ${inputPath}`);
  console.log(`  profile ${args.profile} (available: ${listProfileNames().join(', ')})`);
  console.log(`  out     ${outDir}\n`);

  const source = new Uint8Array(readFileSync(inputPath));
  const run = await runPipeline(source, {
    profileName: args.profile,
    ...(args.quiet
      ? {}
      : { logger: (message, meta) => console.log(`  · ${message}`, JSON.stringify(meta)) }),
  });

  console.log('');
  printTable(run.sourceReport, run.variant?.report);

  for (const note of run.plan.notes) console.log(`  note: ${note}`);

  const stem = basename(inputPath).replace(/\.glb$/i, '');
  const reportPath = join(outDir, `${stem}.report.json`);
  writeFileSync(
    reportPath,
    JSON.stringify(
      {
        source: run.sourceReport,
        plan: run.plan,
        optimized: run.variant?.report ?? null,
        validation: run.validation,
        durationsMs: run.durationsMs,
      },
      null,
      2
    )
  );
  console.log(`\n  wrote ${reportPath}`);

  if (run.plan.skip) {
    console.log(`  skipped: ${run.plan.skipReason}\n`);
    return 0;
  }

  if (!run.validation.ok) {
    console.error('\n  VALIDATION FAILED — nothing written:');
    for (const failure of run.validation.failures) {
      console.error(`    ✗ ${failure.gate}: ${failure.message}`);
    }
    console.error('');
    return 1;
  }

  const webPath = join(outDir, `${stem}.web.glb`);
  writeFileSync(webPath, run.variant!.bytes);
  console.log(`  wrote ${webPath}\n`);
  return 0;
}

main()
  .then((code) => process.exit(code))
  .catch((err: unknown) => {
    console.error(`\n  ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  });
