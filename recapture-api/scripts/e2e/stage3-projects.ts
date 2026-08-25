// scripts/e2e/stage3-projects.ts
//
// Live projects CRUD against the real DB with the minted token:
// create, cursor pagination, get (own / random / other-user), rename,
// soft-delete with confirmName (wrong name 422, right name 200, gone after).
import { Types } from 'mongoose';
import { loadState, saveState, check, finish, api } from './_shared';

async function main(): Promise<void> {
  const state = loadState();
  const tok = state.accessToken!;
  const tok2 = state.user2AccessToken!;
  const tag = state.runTag;

  // 1) create
  const name1 = `${tag}_project_A`;
  const created = await api('POST', '/projects', {
    token: tok,
    body: { name: name1, size: 'medium', mode: 'guided' },
  });
  check(
    'POST /projects → 201 + project',
    created.status === 201 && created.body?.project?.name === name1,
    `got ${created.status}`
  );
  const projectId: string = created.body?.project?.id ?? created.body?.project?._id;

  // 2) pagination: two more projects, then page with limit=2
  const name2 = `${tag}_project_B`;
  const name3 = `${tag}_project_C`;
  await api('POST', '/projects', {
    token: tok,
    body: { name: name2, size: 'small', mode: 'guided' },
  });
  await api('POST', '/projects', {
    token: tok,
    body: { name: name3, size: 'large', mode: 'manual' },
  });

  const page1 = await api('GET', '/projects?limit=2', { token: tok });
  check(
    'GET /projects limit=2 → 2 items + nextCursor',
    page1.status === 200 && page1.body?.items?.length === 2 && !!page1.body?.nextCursor,
    `items=${page1.body?.items?.length}, cursor=${!!page1.body?.nextCursor}`
  );
  const page2 = await api(
    'GET',
    `/projects?limit=2&cursor=${encodeURIComponent(page1.body.nextCursor)}`,
    { token: tok }
  );
  const page1Ids = new Set((page1.body?.items ?? []).map((p: any) => p.id ?? p._id));
  const overlap = (page2.body?.items ?? []).some((p: any) => page1Ids.has(p.id ?? p._id));
  check(
    'cursor page 2 → remaining item(s), no overlap',
    page2.status === 200 && (page2.body?.items?.length ?? 0) >= 1 && !overlap,
    `items=${page2.body?.items?.length}, overlap=${overlap}`
  );

  // 3) get: own / random-id / other user's
  const own = await api('GET', `/projects/${projectId}`, { token: tok });
  check('GET own project → 200', own.status === 200 && own.body?.project);
  const randomId = new Types.ObjectId().toString();
  const missing = await api('GET', `/projects/${randomId}`, { token: tok });
  check('GET random id → 404', missing.status === 404, `got ${missing.status}`);
  const foreign = await api('GET', `/projects/${projectId}`, { token: tok2 });
  check(
    "GET another user's project → 404 (ownership isolation)",
    foreign.status === 404,
    `got ${foreign.status}`
  );

  // 4) rename
  const renamed = await api('PATCH', `/projects/${projectId}`, {
    token: tok,
    body: { name: `${name1}_renamed` },
  });
  check(
    'PATCH rename → 200 + new name',
    renamed.status === 200 && renamed.body?.project?.name === `${name1}_renamed`,
    `got ${renamed.status}`
  );

  // 5) delete: wrong confirmName → 422; right → 200; then gone from list/get
  const wrongConfirm = await api('DELETE', `/projects/${projectId}`, {
    token: tok,
    body: { confirmName: 'totally-wrong-name' },
  });
  check('DELETE wrong confirmName → 422', wrongConfirm.status === 422, `got ${wrongConfirm.status}`);

  const del = await api('DELETE', `/projects/${projectId}`, {
    token: tok,
    body: { confirmName: `${name1}_renamed` },
  });
  check('DELETE right confirmName → 200', del.status === 200, `got ${del.status}`);

  const afterDel = await api('GET', `/projects/${projectId}`, { token: tok });
  check('deleted project GET → 404 (soft-deleted)', afterDel.status === 404, `got ${afterDel.status}`);
  const list = await api('GET', '/projects?limit=50', { token: tok });
  const stillListed = (list.body?.items ?? []).some((p: any) => (p.id ?? p._id) === projectId);
  check('deleted project absent from list', !stillListed);

  // Documented design (projectsService.softDeleteProject): repeat delete is an
  // idempotent 200 no-op that preserves the original deletedAt.
  const delAgain = await api('DELETE', `/projects/${projectId}`, {
    token: tok,
    body: { confirmName: `${name1}_renamed` },
  });
  check(
    'repeat DELETE → 200 idempotent no-op',
    delAgain.status === 200,
    `got ${delAgain.status}`
  );

  saveState({ ...state });
  finish();
}

main().catch((err) => {
  console.error('stage3 crashed:', err);
  process.exit(1);
});
