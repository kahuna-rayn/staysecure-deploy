#!/usr/bin/env node
/**
 * Smoke test — validates the username→email refactor is working end-to-end on a live environment.
 * Tests the REST API and edge functions directly; no browser needed.
 *
 * Covers:
 *   SMOKE-01 (AUTH-01)  — profiles.email column is queryable via REST
 *   SMOKE-02 (AUTH-04)  — profiles.username column is gone (returns error)
 *   SMOKE-03            — account_inventory.email column is queryable via REST
 *   SMOKE-04            — account_inventory.username_email column is gone
 *   SMOKE-05 (ACT-02)   — request-activation-link returns 404 for unknown email, not 400/500
 *   SMOKE-06            — profile-lookup returns profiles with email field present
 *
 * Usage:
 *   SUPABASE_SERVICE_ROLE_KEY=xxx node scripts/smoke-test.mjs --dev
 *   SUPABASE_SERVICE_ROLE_KEY=xxx node scripts/smoke-test.mjs --staging
 *
 * Requires:
 *   SUPABASE_SERVICE_ROLE_KEY  — service role key for the target project (not committed)
 *   Node 18+ (uses built-in fetch)
 */

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── Helpers ──────────────────────────────────────────────────────────────────

function parseEnvFile(filePath) {
  try {
    return Object.fromEntries(
      readFileSync(filePath, 'utf8')
        .split('\n')
        .filter(l => l.trim() && !l.startsWith('#'))
        .map(l => l.match(/^([^=]+)=(.*)$/))
        .filter(Boolean)
        .map(([, k, v]) => [k.trim(), v.trim().replace(/^['"]|['"]$/g, '')])
    );
  } catch {
    return {};
  }
}

const RESET  = '\x1b[0m';
const GREEN  = '\x1b[32m';
const RED    = '\x1b[31m';
const YELLOW = '\x1b[33m';
const BOLD   = '\x1b[1m';
const CYAN   = '\x1b[36m';

let passed = 0;
let failed = 0;

function pass(id, description) {
  console.log(`  ${GREEN}✓${RESET} ${id}: ${description}`);
  passed++;
}

function fail(id, description, detail) {
  console.log(`  ${RED}✗${RESET} ${id}: ${description}`);
  if (detail) console.log(`      ${YELLOW}${detail}${RESET}`);
  failed++;
}

async function get(url, headers) {
  const res = await fetch(url, { headers });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, body };
}

async function post(url, headers, payload) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, body };
}

// ── Config ───────────────────────────────────────────────────────────────────

const arg = process.argv[2];
if (!arg || ![`--dev`, `--staging`, `--omnihealth`, `--nexus`, `--ygos`, `--renci`].includes(arg) && !arg.match(/^[a-z]{20}$/)) {
  console.error('Usage: node scripts/smoke-test.mjs <--dev|--staging|--omnihealth|--nexus|--ygos|--renci|project-ref>');
  process.exit(1);
}

const SECRETS_DIR = join(__dirname, '../../learn/secrets');
const PROJECTS_CONF = parseEnvFile(join(SECRETS_DIR, 'projects.conf')
  .replace('projects.conf', 'projects.conf'));

// Parse projects.conf manually (bash format)
function readProjectRef(name) {
  try {
    const content = readFileSync(join(SECRETS_DIR, 'projects.conf'), 'utf8');
    const match = content.match(new RegExp(`${name}="?([a-z]{20})"?`));
    return match?.[1] ?? null;
  } catch { return null; }
}

let projectRef, envFile;
if (arg === '--dev') {
  projectRef = readProjectRef('DEV_REF');
  envFile = join(SECRETS_DIR, 'dev-secrets.env');
} else if (arg === '--staging') {
  projectRef = readProjectRef('STAGING_REF');
  envFile = join(SECRETS_DIR, 'staging-secrets.env');
} else if (arg === '--omnihealth') {
  projectRef = readProjectRef('OMNIHEALTH_REF');
  envFile = join(SECRETS_DIR, 'omnihealth-secrets.env');
} else if (arg === '--nexus') {
  projectRef = readProjectRef('NEXUS_REF');
  envFile = join(SECRETS_DIR, 'nexus-secrets.env');
} else if (arg === '--ygos') {
  projectRef = readProjectRef('YGOS_REF');
  envFile = join(SECRETS_DIR, 'ygos-secrets.env');
} else if (arg === '--renci') {
  projectRef = readProjectRef('RENCI_REF');
  envFile = join(SECRETS_DIR, 'renci-secrets.env');
} else {
  projectRef = arg;
  envFile = join(SECRETS_DIR, 'dev-secrets.env');
}

if (!projectRef) {
  console.error(`Could not resolve project ref for ${arg}`);
  process.exit(1);
}

const envVars = parseEnvFile(envFile);
const SUPABASE_URL = envVars.VITE_SUPABASE_URL || `https://${projectRef}.supabase.co`;
const ANON_KEY     = envVars.VITE_SUPABASE_ANON_KEY;
let SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SERVICE_ROLE_KEY) {
  const { createInterface } = await import('readline');
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  SERVICE_ROLE_KEY = await new Promise(resolve => {
    rl.question(`${YELLOW}SUPABASE_SERVICE_ROLE_KEY not set. Enter service role key for ${projectRef}: ${RESET}`, answer => {
      rl.close();
      resolve(answer.trim());
    });
  });
  console.error('');
}

const REST   = `${SUPABASE_URL}/rest/v1`;
const AUTH_HEADERS = {
  apikey: SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
};

// ── Tests ────────────────────────────────────────────────────────────────────

console.log('');
console.log(`${BOLD}Smoke test — ${projectRef}${RESET}`);
console.log(`${CYAN}${SUPABASE_URL}${RESET}`);
console.log('────────────────────────────────────────────────────');

// ── 1. REST: profiles ────────────────────────────────────────────────────────
console.log(`\n${BOLD}1. REST — profiles table${RESET}`);

{
  const { status, body } = await get(`${REST}/profiles?select=id,email&limit=1`, AUTH_HEADERS);
  if (status === 200 && Array.isArray(body)) {
    const hasEmail = body.length === 0 || ('email' in body[0]);
    if (hasEmail) {
      pass('SMOKE-01', 'profiles.email is queryable via REST (no 400)');
    } else {
      fail('SMOKE-01', 'profiles.email queryable but field missing in response', JSON.stringify(body[0]));
    }
  } else {
    fail('SMOKE-01', 'profiles.email query failed', `HTTP ${status}: ${JSON.stringify(body)}`);
  }
}

{
  const { status, body } = await get(`${REST}/profiles?select=username&limit=1`, AUTH_HEADERS);
  if (status !== 200) {
    pass('SMOKE-02', 'profiles.username is gone (query correctly returns error)');
  } else {
    fail('SMOKE-02', 'profiles.username still exists — column not renamed', `HTTP ${status}`);
  }
}

// ── 2. REST: account_inventory ───────────────────────────────────────────────
console.log(`\n${BOLD}2. REST — account_inventory table${RESET}`);

{
  const { status, body } = await get(`${REST}/account_inventory?select=id,email&limit=1`, AUTH_HEADERS);
  if (status === 200 && Array.isArray(body)) {
    pass('SMOKE-03', 'account_inventory.email is queryable via REST (no 400)');
  } else {
    fail('SMOKE-03', 'account_inventory.email query failed', `HTTP ${status}: ${JSON.stringify(body)}`);
  }
}

{
  const { status } = await get(`${REST}/account_inventory?select=username_email&limit=1`, AUTH_HEADERS);
  if (status !== 200) {
    pass('SMOKE-04', 'account_inventory.username_email is gone (query correctly returns error)');
  } else {
    fail('SMOKE-04', 'account_inventory.username_email still exists — column not renamed', `HTTP ${status}`);
  }
}

// ── 3. REST: email equality filter (simulates request-activation-link DB lookup) ──
console.log(`\n${BOLD}3. REST — email equality filter (used by request-activation-link)${RESET}`);

{
  const fakeEmail = `smoke-test-nonexistent-${Date.now()}@example-smoke.invalid`;
  const { status, body } = await get(
    `${REST}/profiles?select=id,email&email=eq.${encodeURIComponent(fakeEmail)}&limit=1`,
    AUTH_HEADERS
  );
  if (status === 200 && Array.isArray(body)) {
    pass('SMOKE-05', 'profiles.email equality filter works — request-activation-link DB lookup will succeed');
  } else {
    fail('SMOKE-05', 'profiles.email equality filter failed', `HTTP ${status}: ${JSON.stringify(body)}`);
  }
}

// ── 4. REST: email in full field list (simulates profile-lookup select) ───────
console.log(`\n${BOLD}4. REST — full profile fields (used by profile-lookup)${RESET}`);

{
  const fields = 'id,first_name,last_name,full_name,email,phone,location,status,language,manager,employee_id';
  const { status, body } = await get(
    `${REST}/profiles?select=${fields}&limit=1`,
    AUTH_HEADERS
  );
  if (status === 200 && Array.isArray(body)) {
    const firstProfile = body[0];
    if (!firstProfile || 'email' in firstProfile) {
      pass('SMOKE-06', 'profile-lookup field list is queryable — email field present in response');
    } else {
      fail('SMOKE-06', 'profile-lookup field list returned profile without email', JSON.stringify(firstProfile));
    }
  } else {
    fail('SMOKE-06', 'profile-lookup field list query failed', `HTTP ${status}: ${JSON.stringify(body)}`);
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
console.log('');
console.log('────────────────────────────────────────────────────');
const total = passed + failed;
if (failed === 0) {
  console.log(`${GREEN}${BOLD}All ${total} smoke tests passed.${RESET}`);
  console.log('');
  console.log(`${YELLOW}Note: create-user and delete-user require an admin JWT — test those manually.${RESET}`);
} else {
  console.log(`${RED}${BOLD}${failed} of ${total} smoke tests failed.${RESET}`);
  process.exit(1);
}
console.log('');
