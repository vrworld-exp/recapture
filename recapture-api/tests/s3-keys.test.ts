// tests/s3-keys.test.ts
//
// Canonical S3 key utility (@/utils/s3Keys) — pure unit tests, no DB/S3.
// Under the vitest config NODE_ENV=development, so every built key must start
// with "dev/" (config-driven env prefix — never a hardcoded "prod").
import { describe, it, expect } from 'vitest';

import {
  S3KeyError,
  s3EnvPrefix,
  s3EnvPrefixFor,
  normalizeCaptureLevel,
  projectNameSlug,
  buildJobKeyPrefix,
  buildJobImagePrefix,
  buildLevelImagePrefix,
  buildManifestKey,
  buildImageKey,
  parseImageKey,
  CAPTURE_LEVEL_SEGMENTS,
  MANIFEST_FILENAME,
} from '@/utils/s3Keys';

/** A realistic scope: an ObjectId-hex projectId under a human project name. */
const PROJECT_ID = '665f1c2b8a9d3e0087654321';
const JOB_ID = '665f1c2b8a9d3e00abcdef12';
const scope = { projectName: 'Brass Vase', projectId: PROJECT_ID, jobId: JOB_ID };
const ROOT = `dev/brass-vase_${PROJECT_ID}/${JOB_ID}/`;

describe('env prefix — config-driven, never hardcoded', () => {
  it('maps NODE_ENV production/staging/development → prod/staging/dev', () => {
    expect(s3EnvPrefixFor('production')).toBe('prod');
    expect(s3EnvPrefixFor('staging')).toBe('staging');
    expect(s3EnvPrefixFor('development')).toBe('dev');
  });

  it('under the test config (NODE_ENV=development) keys start with dev/, not prod/', () => {
    expect(s3EnvPrefix()).toBe('dev');
    const key = buildImageKey({ ...scope, level: 'EYE', filename: 'frame_0001.jpg' });
    expect(key.startsWith('dev/')).toBe(true);
    expect(key.startsWith('prod')).toBe(false);
    expect(key.startsWith('staging')).toBe(false);
  });

  it('{env} is still the FIRST segment of every builder — the delete firewall', () => {
    // The project-delete path wipes objects by this prefix in BOTH buckets, so
    // a staging deploy losing its env segment would delete production objects.
    for (const built of [
      buildJobKeyPrefix(scope),
      buildJobImagePrefix(scope),
      buildLevelImagePrefix(scope, 'EYE'),
      buildManifestKey(scope),
      buildImageKey({ ...scope, level: 'LOW', filename: 'f.jpg' }),
    ]) {
      expect(built.split('/')[0]).toBe('dev');
    }
  });
});

describe('projectNameSlug — user-authored free text → one safe label', () => {
  it('lowercases and collapses spaces/punctuation to single hyphens', () => {
    expect(projectNameSlug('Brass Vase')).toBe('brass-vase');
    expect(projectNameSlug('  Brass   Vase!!  ')).toBe('brass-vase');
    expect(projectNameSlug('Vase (v2) — FINAL')).toBe('vase-v2-final');
  });

  it('NFKD-normalizes and strips diacritics', () => {
    expect(projectNameSlug('café')).toBe('cafe');
    expect(projectNameSlug('Cafe\u0301')).toBe('cafe'); // decomposed e + U+0301
    expect(projectNameSlug('Zürich Ätna')).toBe('zurich-atna');
  });

  it('preserves underscores (the segment splits on the LAST one, so they are safe)', () => {
    expect(projectNameSlug('my_project_v2')).toBe('my_project_v2');
    expect(projectNameSlug('My Project_v2')).toBe('my-project_v2');
  });

  it('keeps leading digits (SEGMENT_RE wants an alphanumeric first char)', () => {
    expect(projectNameSlug('3D Bust')).toBe('3d-bust');
    expect(projectNameSlug('007')).toBe('007');
  });

  it('never lets a separator survive — no traversal, no hierarchy injection', () => {
    expect(projectNameSlug('a/b')).toBe('a-b');
    expect(projectNameSlug('a\\b')).toBe('a-b');
    expect(projectNameSlug('../../etc/passwd')).toBe('etc-passwd');
    expect(projectNameSlug('..')).toBe('');
    expect(projectNameSlug('.hidden')).toBe('hidden');
    for (const name of ['a/b', 'a\\b', '../../etc/passwd', '.hidden']) {
      expect(projectNameSlug(name)).toMatch(/^[a-z0-9][a-z0-9_-]*$/);
    }
  });

  it('strips leading and trailing separators', () => {
    expect(projectNameSlug('---vase---')).toBe('vase');
    expect(projectNameSlug('___vase___')).toBe('vase');
    expect(projectNameSlug('!!!vase???')).toBe('vase');
  });

  it('an emoji-only name yields the empty string and does NOT throw', () => {
    expect(projectNameSlug('🗿🗿🗿')).toBe('');
    expect(projectNameSlug('🙂 🎉')).toBe('');
    expect(projectNameSlug('')).toBe('');
    expect(projectNameSlug('...')).toBe('');
  });

  it('truncates to 24 chars and never leaves a trailing separator', () => {
    // Project.name is maxlength 100 — a name at the limit must still slugify.
    const atMaxLength = 'A'.repeat(100);
    expect(atMaxLength).toHaveLength(100);
    expect(projectNameSlug(atMaxLength)).toBe('a'.repeat(24));

    const wordy = 'The Extremely Long Museum Artifact Name Of Doom';
    const slug = projectNameSlug(wordy);
    expect(slug.length).toBeLessThanOrEqual(24);
    expect(slug).toBe('the-extremely-long-museu');
    expect(slug.endsWith('-')).toBe(false);

    // The cut lands exactly ON a hyphen → it must be re-stripped. The fixture is
    // sized to the cap: 23 chars + a separator puts the 24th char on the hyphen.
    const cutOnSeparator = `${'a'.repeat(23)} tail`;
    expect(projectNameSlug(cutOnSeparator)).toBe('a'.repeat(23));

    for (let n = 1; n <= 60; n += 1) {
      const s = projectNameSlug('word '.repeat(n));
      expect(s.length).toBeLessThanOrEqual(24);
      expect(s).toMatch(/^[a-z0-9][a-z0-9_-]*$/);
    }
  });

  it('is pure and deterministic — same name, same slug, every time', () => {
    const names = ['Brass Vase', 'café', '🗿', 'my_project_v2', 'A'.repeat(100)];
    for (const name of names) {
      const first = projectNameSlug(name);
      for (let i = 0; i < 5; i += 1) {
        expect(projectNameSlug(name)).toBe(first);
      }
    }
  });
});

describe('buildImageKey — exact format', () => {
  it('produces {env}/{slug}_{projectId}/{jobId}/images/{LEVEL}/{filename}.jpg per level', () => {
    for (const level of CAPTURE_LEVEL_SEGMENTS) {
      expect(buildImageKey({ ...scope, level, filename: 'frame_0001.jpg' })).toBe(
        `${ROOT}images/${level}/frame_0001.jpg`
      );
    }
  });

  it('normalizes level codes A/B/C and lowercase ring names to ring segments', () => {
    expect(buildImageKey({ ...scope, level: 'A', filename: 'f.jpg' })).toContain('/images/EYE/');
    expect(buildImageKey({ ...scope, level: 'B', filename: 'f.jpg' })).toContain('/images/TOP/');
    expect(buildImageKey({ ...scope, level: 'C', filename: 'f.jpg' })).toContain('/images/LOW/');
    expect(buildImageKey({ ...scope, level: 'eye', filename: 'f.jpg' })).toContain('/images/EYE/');
  });

  it('always terminates in exactly one lowercase .jpg', () => {
    const expected = `${ROOT}images/EYE/frame_0001.jpg`;
    expect(buildImageKey({ ...scope, level: 'EYE', filename: 'frame_0001' })).toBe(expected);
    expect(buildImageKey({ ...scope, level: 'EYE', filename: 'frame_0001.jpg' })).toBe(expected);
    expect(buildImageKey({ ...scope, level: 'EYE', filename: 'frame_0001.JPG' })).toBe(expected);
    expect(buildImageKey({ ...scope, level: 'EYE', filename: 'frame_0001.jpg.jpg' })).toBe(expected);
  });
});

describe('prefix + manifest builders', () => {
  it('job root, images/, per-level prefixes and manifest key nest consistently', () => {
    const root = buildJobKeyPrefix(scope);
    expect(root).toBe(ROOT);
    expect(buildJobImagePrefix(scope)).toBe(`${root}images/`);
    expect(buildLevelImagePrefix(scope, 'TOP')).toBe(`${root}images/TOP/`);
    expect(buildManifestKey(scope)).toBe(`${root}${MANIFEST_FILENAME}`);
    expect(
      buildImageKey({ ...scope, level: 'TOP', filename: 'x.jpg' }).startsWith(
        buildJobImagePrefix(scope)
      )
    ).toBe(true);
  });

  it('the project NAME is embedded, and the user id is NOT in the path', () => {
    const userId = '665f1c2b8a9d3e0012345678';
    const root = buildJobKeyPrefix(scope);
    expect(root).toContain('brass-vase');
    expect(root).not.toContain(userId);
    expect(root.split('/')).toHaveLength(4); // env, project, job, trailing ''
  });

  it('a name that slugifies to nothing degrades to a bare {projectId} — no leading "_"', () => {
    for (const projectName of ['🗿🗿', '', '...', '   ']) {
      const root = buildJobKeyPrefix({ ...scope, projectName });
      expect(root).toBe(`dev/${PROJECT_ID}/${JOB_ID}/`);
      expect(root).not.toContain('/_');
    }
  });

  it('slugifies internally, so a caller cannot forget to (raw name in ⇒ slug out)', () => {
    expect(buildJobKeyPrefix({ ...scope, projectName: 'Café / Vase' })).toBe(
      `dev/cafe-vase_${PROJECT_ID}/${JOB_ID}/`
    );
  });
});

describe('segment sanitization — no traversal / injection', () => {
  const bad = ['', '..', '../evil', 'a/b', 'a\\b', 'a b', ' a', '.hidden', 'a\nb'];

  it('rejects hostile id segments with S3KeyError', () => {
    for (const value of bad) {
      expect(() => buildJobKeyPrefix({ ...scope, projectId: value })).toThrow(S3KeyError);
      expect(() => buildJobKeyPrefix({ ...scope, jobId: value })).toThrow(S3KeyError);
    }
  });

  it('a hostile project NAME is slugified, never rejected — and never escapes', () => {
    for (const projectName of bad) {
      const root = buildJobKeyPrefix({ ...scope, projectName });
      expect(root.split('/')).toHaveLength(4);
      expect(root.endsWith(`${PROJECT_ID}/${JOB_ID}/`)).toBe(true);
    }
  });

  it('rejects hostile filenames (separators, traversal, whitespace, bare extension)', () => {
    for (const value of [...bad, '.jpg', '.JPG.jpg']) {
      expect(() => buildImageKey({ ...scope, level: 'EYE', filename: value })).toThrow(S3KeyError);
    }
  });

  it('rejects levels outside the closed set', () => {
    for (const value of ['D', 'MID', '', 'images', 'EYE/..']) {
      expect(() => normalizeCaptureLevel(value)).toThrow(S3KeyError);
    }
  });
});

describe('parseImageKey — round-trip + strict rejection', () => {
  it('round-trips every canonical build input exactly', () => {
    const matrix = [
      { projectName: 'Brass Vase', projectId: PROJECT_ID, jobId: JOB_ID },
      { projectName: '🗿', projectId: PROJECT_ID, jobId: JOB_ID }, // slug-less
      {
        projectName: 'my_project_v2',
        projectId: '665f1c2b8a9d3e0011112222',
        jobId: '665f1c2b8a9d3e0033334444',
      },
    ];
    for (const s of matrix) {
      for (const level of CAPTURE_LEVEL_SEGMENTS) {
        for (const filename of ['eye_0001.jpg', 'frame-9.9.jpg']) {
          const parsed = parseImageKey(buildImageKey({ ...s, level, filename }));
          expect(parsed).toEqual({
            ok: true,
            value: {
              env: 'dev',
              projectSlug: projectNameSlug(s.projectName),
              projectId: s.projectId,
              jobId: s.jobId,
              level,
              filename,
            },
          });
        }
      }
    }
  });

  it('splits on the LAST underscore, so a slug containing "_" keeps the id intact', () => {
    // Project ids are ObjectId hex — [a-f0-9]{24}, no underscore — which is
    // exactly what makes the last-underscore split unambiguous.
    expect(PROJECT_ID).toMatch(/^[a-f0-9]{24}$/);
    expect(PROJECT_ID).not.toContain('_');

    const slugWithUnderscores = { ...scope, projectName: 'a_b_c__d' };
    expect(projectNameSlug(slugWithUnderscores.projectName)).toBe('a_b_c__d');

    const key = buildImageKey({ ...slugWithUnderscores, level: 'EYE', filename: 'e_1.jpg' });
    expect(key).toBe(`dev/a_b_c__d_${PROJECT_ID}/${JOB_ID}/images/EYE/e_1.jpg`);

    const parsed = parseImageKey(key);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.value.projectId).toBe(PROJECT_ID);
      expect(parsed.value.projectSlug).toBe('a_b_c__d');
    }
  });

  it('a slug-less segment parses as projectSlug: "" with the whole segment as the id', () => {
    const parsed = parseImageKey(`dev/${PROJECT_ID}/${JOB_ID}/images/EYE/a.jpg`);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.value.projectSlug).toBe('');
      expect(parsed.value.projectId).toBe(PROJECT_ID);
    }
  });

  it('a stem-only filename parses back with the single appended extension', () => {
    const parsed = parseImageKey(buildImageKey({ ...scope, level: 'LOW', filename: 'frame_2' }));
    expect(parsed.ok && parsed.value.filename).toBe('frame_2.jpg');
  });

  it('an OLD 7-segment key is a clean failure, never a crash or a partial parse', () => {
    // The pre-change scheme: {env}/{userId}/{projectId}/{jobId}/images/{LEVEL}/f.jpg
    const legacy = `dev/665f1c2b8a9d3e0012345678/${PROJECT_ID}/${JOB_ID}/images/EYE/eye_0001.jpg`;
    expect(legacy.split('/')).toHaveLength(7);
    const parsed = parseImageKey(legacy);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.reason).toContain('6 segments');
  });

  it('rejects non-conforming keys with an explicit failure (never partial)', () => {
    const malformed = [
      `dev/p_${PROJECT_ID}/j/images/EYE`, // wrong depth (no filename)
      `dev/p_${PROJECT_ID}/j/images/EYE/a/b.jpg`, // too deep
      `dev/p_${PROJECT_ID}/j/photos/EYE/a.jpg`, // missing literal "images"
      `dev/p_${PROJECT_ID}/j/images/eye/a.jpg`, // lowercase level
      `dev/p_${PROJECT_ID}/j/images/A/a.jpg`, // level code instead of ring name
      `dev/p_${PROJECT_ID}/j/images/EYE/a.png`, // wrong extension
      `dev/p_${PROJECT_ID}/j/images/EYE/a.JPG`, // uppercase extension
      `dev/p_${PROJECT_ID}/j/images/EYE/a.jpg.jpg`, // doubled extension
      `production/p_${PROJECT_ID}/j/images/EYE/a.jpg`, // unknown env prefix
      'dev/../j/images/EYE/a.jpg', // traversal segment
      'dev//j/images/EYE/a.jpg', // empty segment
      `dev/_${PROJECT_ID}/j/images/EYE/a.jpg`, // leading "_" (never emitted)
      `dev/p_${PROJECT_ID}/j/capture_manifest.json`, // manifest, not an image key
      '',
    ];
    for (const key of malformed) {
      const parsed = parseImageKey(key);
      expect(parsed.ok, `expected rejection for ${JSON.stringify(key)}`).toBe(false);
      if (!parsed.ok) expect(parsed.reason.length).toBeGreaterThan(0);
    }
  });
});
