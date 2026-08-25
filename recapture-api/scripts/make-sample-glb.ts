// scripts/make-sample-glb.ts
//
//   npx tsx scripts/make-sample-glb.ts [outPath]
//
// Writes a synthetic Meshy-SHAPED GLB (~8 MB: a 2k base-colour map, a flat
// metallicRoughness map, an orphan texture, real-world scale on the node) so
// the pipeline CLI can be exercised without a real Meshy credit.
//
// It is NOT a substitute for testing on real Meshy output — drop actual .glb
// files into samples/ for that. This exists so a fresh clone can run
// `npm run pipeline` immediately.
import { writeFileSync } from 'node:fs';
import { makeMeshyLikeGlb } from '../tests/fixtures/glbFactory';

async function main(): Promise<void> {
  const out = process.argv[2] ?? 'samples/dish.glb';
  const { glb } = await makeMeshyLikeGlb({
    gridSize: 64,
    baseColorSize: 2048,
    constantMetalRough: true,
    withUnusedTexture: true,
    sizeMeters: 0.28,
  });
  writeFileSync(out, glb);
  console.log(`wrote ${out} — ${(glb.byteLength / 1e6).toFixed(2)} MB`);
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
