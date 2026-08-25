// scripts/e2e/_shared.ts
//
// Shared helpers for the live E2E verification run (phases 0–6).
// State is chained between stage scripts via a JSON file OUTSIDE the repo.
// Tokens/secrets are written only to that file, never to stdout.
import fs from 'fs';
import path from 'path';
import mongoose from 'mongoose';
import { env } from '../../src/config/env';

export const API = 'http://localhost:3000';

export const STATE_PATH = path.join(
  'C:\\Users\\DELL\\AppData\\Local\\Temp\\claude\\d--ASHISH-K3-VR-World-Code-ReCapture\\ed9a5d74-0df6-4504-8fad-c88cdff930d6\\scratchpad',
  'e2e-state.json'
);

export interface E2EState {
  runTag: string;
  userId?: string;
  authUid?: string;
  accessToken?: string;
  user2Id?: string;
  user2AccessToken?: string;
  projectId?: string;
  jobId?: string;
  badJobId?: string;
  plannedKeys?: string[];
  jobRootPrefix?: string;
  uploadedKeys?: string[];
  artifactKeys?: string[];
  [k: string]: unknown;
}

export function loadState(): E2EState {
  if (!fs.existsSync(STATE_PATH)) {
    return { runTag: `e2e_${Date.now()}` };
  }
  return JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')) as E2EState;
}

export function saveState(state: E2EState): void {
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

export async function connectDb(): Promise<void> {
  await mongoose.connect(env.MONGODB_URI);
}

export async function disconnectDb(): Promise<void> {
  await mongoose.disconnect();
}

// ── tiny check harness ────────────────────────────────────────────────────────
let failures = 0;

export function check(name: string, ok: boolean, detail = ''): void {
  if (!ok) failures++;
  console.log(`  ${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
}

export function finish(): never {
  console.log(failures === 0 ? 'STAGE PASSED' : `STAGE FAILED (${failures} checks)`);
  process.exit(failures === 0 ? 0 : 1);
}

/** JSON fetch against the local API; returns status + parsed body. */
export async function api(
  method: string,
  route: string,
  opts: { token?: string; body?: unknown; headers?: Record<string, string> } = {}
): Promise<{ status: number; body: any; headers: Headers }> {
  const res = await fetch(`${API}${route}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
      ...(opts.headers ?? {}),
    },
    ...(opts.body !== undefined ? { body: JSON.stringify(opts.body) } : {}),
  });
  let body: any = null;
  const text = await res.text();
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: res.status, body, headers: res.headers };
}
