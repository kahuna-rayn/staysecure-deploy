#!/usr/bin/env npx ts-node
/**
 * Psybersafe → StaySecure Learn migration script
 *
 * Reads a single Psybersafe Excel workbook and classifies each user into a
 * learning cohort, creates their StaySecure account, writes track/lesson/
 * certificate records, and optionally sends activation emails.
 *
 * ─── Expected workbook sheets ────────────────────────────────────────────────
 *
 *   Status      Registration status — columns: First Name, Last Name, Email, Status
 *   Score       Quiz scores        — columns: Fullname, Email, Result
 *   <date>      Learner progress   — columns: Learner, <10 episode cols>, Quiz!, Score
 *               (use the most recent date sheet, e.g. "20251230")
 *
 * ─── Modes ───────────────────────────────────────────────────────────────────
 *
 *  (no flag)    Preview only — classify users, print report, zero DB writes.
 *
 *  --dry-run    Create users + write all records. NO activation emails.
 *               Use this to load data and verify everything looks right in
 *               the app before sending any emails.
 *
 *  --migrate    Full production run — create users + write all records +
 *               send activation emails via request-activation-link.
 *               Idempotent: already-created users are skipped for creation
 *               but still receive an activation email.
 *
 * ─── Usage ───────────────────────────────────────────────────────────────────
 *
 *   npx ts-node migrate-psybersafe-users.ts \
 *     --xlsx "YGOS Learn Progress Report 20251230.xlsx" \
 *     --progress-sheet 20251230 \
 *     [--business-line-col "Business Line"] \
 *     [--dry-run | --migrate]
 *
 * ─── Optional flags ───────────────────────────────────────────────────────────
 *
 *   --business-line-col <col>   Column name for the department/business-line value.
 *                               Checked in the Status sheet first, then the progress
 *                               sheet. Defaults to "Business Line". If the column is
 *                               absent in both sheets, department assignment is skipped.
 *                               Departments are created automatically if they don't exist.
 *
 *   Env vars are loaded automatically from the nearest .env.local or .env file
 *   (searches deploy/scripts/ then deploy/). You can also pass them inline.
 *
 * ─── Required env vars ───────────────────────────────────────────────────────
 *
 *   SUPABASE_URL              e.g. https://orolrurwgwceaohtpwdc.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY Service role key (not anon key)
 *   APP_BASE_URL              Learn app base URL for this client instance
 *                             e.g. https://staysecure-learn.raynsecure.com
 *   CLIENT_PATH               Tenant path segment  e.g. /nexus  (empty for dev/staging)
 *
 * ─── Dependencies (install once in deploy/scripts/) ──────────────────────────
 *
 *   npm install @supabase/supabase-js xlsx
 *   npm install -D @types/node ts-node typescript
 */

import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';
import { createClient } from '@supabase/supabase-js';
import * as XLSX from 'xlsx';

// ---------------------------------------------------------------------------
// .env loader — searches deploy/scripts/ then deploy/ for .env.local / .env
// ---------------------------------------------------------------------------
(function loadEnv() {
  const parseFile = (file: string, override: boolean) => {
    if (!fs.existsSync(file)) return false;
    const lines = fs.readFileSync(file, 'utf-8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim().replace(/^export\s+/, '');
      const val = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      if (override || !(key in process.env)) process.env[key] = val;
    }
    console.log(`📄 Loaded env from ${file}`);
    return true;
  };

  // .env.local always overrides shell environment (client-specific config)
  // .env only fills in vars not already set
  const localLoaded =
    parseFile(path.resolve(__dirname, '.env.local'), true) ||
    parseFile(path.resolve(__dirname, '..', '.env.local'), true);

  if (!localLoaded) {
    parseFile(path.resolve(__dirname, '.env'), false) ||
    parseFile(path.resolve(__dirname, '..', '.env'), false);
  } else {
    // Also load base .env for any vars not in .env.local
    parseFile(path.resolve(__dirname, '.env'), false) ||
    parseFile(path.resolve(__dirname, '..', '.env'), false);
  }
})();

// ---------------------------------------------------------------------------
// Configuration — verify before running
// ---------------------------------------------------------------------------

/** UUIDs are stable across all environments (synced via Lesson Sync). */
const TRACK_IDS = {
  cybersecurityFoundation:   '3a0a6b51-0108-4b22-83c5-eb258486d7c8',
  cybersecurityFoundationII: '84caaddd-1869-405f-b408-4e770b1bc870',
  cybersecurityIntermediate: '4a7e7014-9b1f-4f90-be2e-d1a8a06afd04',
} as const;

/**
 * The 10 episode column headers exactly as they appear in the progress sheet.
 * Verified against "YGOS Learn Progress Report 20251230.xlsx" → sheet 20251230.
 */
const EPISODE_COLUMNS = [
  'Welcome!',
  "I don't think so, friend!",
  "Sharing isn't Caring",
  'Return of the Hack',
  'Forget Me Not',
  'Catch of the Day',
  'Now What?!',
  "A King's Ransom",
  'Whose data is this?',
  'Go Phish!',
];

const QUIZ_PASS_SCORE    = 16;   // 80% of 20
const CERTIFICATE_NAME   = 'Cybersecurity Foundation';
const CERTIFICATE_ISSUER = 'RAYN Secure Pte Ltd';
const CERTIFICATE_TYPE   = 'Quiz Completion';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Mode   = 'preview' | 'dry-run' | 'migrate';
type Cohort = 'E1' | 'E2' | 'E3';

interface StatusRow {
  'First Name': string;
  'Last Name':  string;
  Email:        string;
  Status:       string; // "Registered" | "Pending"
  [key: string]: string;
}

interface ScoreRow {
  Fullname:  string;
  Email:     string;
  Result:    number | string;
  [key: string]: unknown;
}

interface ProgressRow {
  Learner: string;
  Score:   number | string; // numeric or "#N/A"
  'Quiz!': number | string; // Excel serial date or empty
  [key: string]: unknown;
}

interface UserMigration {
  email:             string;
  fullName:          string;
  firstName:         string;
  lastName:          string;
  cohort:            Cohort;
  episodesCompleted: number;
  quizScore:         number | null;
  businessLine?:     string;
  userId?:           string;
}

// ---------------------------------------------------------------------------
// Excel reading
// ---------------------------------------------------------------------------

function readSheet<T>(wb: XLSX.WorkBook, sheetName: string): T[] {
  const ws = wb.Sheets[sheetName];
  if (!ws) throw new Error(`Sheet "${sheetName}" not found. Available: ${wb.SheetNames.join(', ')}`);
  return XLSX.utils.sheet_to_json<T>(ws, { defval: '' });
}

// ---------------------------------------------------------------------------
// Classification logic
// ---------------------------------------------------------------------------

function countCompletedEpisodes(row: ProgressRow): number {
  return EPISODE_COLUMNS.filter((col) => {
    const val = row[col];
    if (val === '' || val === null || val === undefined) return false;
    if (typeof val === 'string') {
      const s = val.trim().toLowerCase();
      return s !== '' && s !== '-' && s !== 'in-progress';
    }
    // Excel serial date (number) → completed
    return typeof val === 'number';
  }).length;
}

function parseScore(raw: unknown): number | null {
  if (raw === null || raw === undefined || raw === '') return null;
  if (typeof raw === 'number') return raw;
  const s = String(raw).trim();
  if (s === '#N/A' || s === '-' || s === '') return null;
  const n = parseFloat(s);
  return isNaN(n) ? null : n;
}

function classifyUser(progressRow: ProgressRow | undefined, scoreSheetScore: number | null): {
  cohort:            Cohort;
  episodesCompleted: number;
  quizScore:         number | null;
} {
  if (!progressRow) return { cohort: 'E1', episodesCompleted: 0, quizScore: scoreSheetScore };

  const episodesCompleted = countCompletedEpisodes(progressRow);
  // Prefer progress sheet score; fall back to Score sheet result
  const quizScore  = parseScore(progressRow['Score']) ?? scoreSheetScore;
  const quizPassed = quizScore !== null && quizScore >= QUIZ_PASS_SCORE;

  let cohort: Cohort;
  if (episodesCompleted < 5) {
    cohort = 'E1';
  } else if (episodesCompleted < 10 || !quizPassed) {
    cohort = 'E2';
  } else {
    cohort = 'E3';
  }
  return { cohort, episodesCompleted, quizScore };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function prompt(question: string): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(question, (ans) => { rl.close(); resolve(ans); }));
}

async function preflight(mode: Mode, xlsxPath: string, statusSheet: string, scoreSheet: string, progressSheet: string): Promise<void> {
  const modeLabel =
    mode === 'preview'  ? '📋 PREVIEW — classify only, zero writes' :
    mode === 'dry-run'  ? '🔵 DRY RUN — create users + records, NO emails' :
                          '🚀 MIGRATE — create users + records + send activation emails';

  console.log(`
╔══════════════════════════════════════════════════════════════════╗
║          Psybersafe → StaySecure Learn Migration Script          ║
╚══════════════════════════════════════════════════════════════════╝

  Mode:             ${modeLabel}
  Workbook:         ${xlsxPath}
  Status sheet:     ${statusSheet}
  Score sheet:      ${scoreSheet}
  Progress sheet:   ${progressSheet}

Before continuing, confirm the following for this client instance:

  1. All three learning tracks have been synced from master and
     exist in this client's Supabase DB:
       • Cybersecurity Foundation
       • Cybersecurity Foundation II
       • Cybersecurity Intermediate

  2. TRACK_IDS at the top of this script are correct for this client.

  3. EPISODE_COLUMNS match the column headers in the progress sheet.

  4. SUPABASE_URL, APP_BASE_URL, and CLIENT_PATH env vars point to
     the correct client instance.
`);

  const answer = await prompt('Ready to go? (y/N): ');
  if (answer.trim().toLowerCase() !== 'y') {
    console.log('\nAborted.');
    process.exit(0);
  }
  console.log('');
}

// ---------------------------------------------------------------------------
// User creation
// ---------------------------------------------------------------------------

async function createUser(
  supabase: any,
  serviceRoleKey: string,
  user: { email: string; fullName: string; firstName: string; lastName: string },
  clientPath: string,
  appBaseUrl: string,
): Promise<string | null | 'already_exists'> {
  try {
    const { data, error } = await supabase.functions.invoke('create-user', {
      body: {
        email:                 user.email,
        full_name:             user.fullName,
        first_name:            user.firstName,
        last_name:             user.lastName,
        username:              user.email,
        status:                'Pending',
        access_level:          'user',
        clientPath,
        skip_activation_email: true,
      },
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        Origin:        appBaseUrl,
      },
    });

    if (error) {
      console.error(`   ✗ create-user edge function error for ${user.email}:`, error);
      return null;
    }
    if (data?.error) {
      if (
        data.error.includes('already registered') ||
        data.error.includes('already been registered') ||
        data.error.includes('already exists')
      ) {
        return 'already_exists';
      }
      console.error(`   ✗ create-user error for ${user.email}: ${data.error}`);
      return null;
    }
    return data?.user?.id ?? null;
  } catch (err) {
    console.error(`   ✗ create-user threw for ${user.email}:`, err);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Activation email
// ---------------------------------------------------------------------------

async function sendActivationEmail(
  supabase: any,
  serviceRoleKey: string,
  email: string,
  appBaseUrl: string,
  clientPath: string,
): Promise<void> {
  const redirectUrl = `${appBaseUrl}${clientPath}/activate-account`;
  const { error } = await supabase.functions.invoke('request-activation-link', {
    body: { email, redirectUrl },
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      Origin:        appBaseUrl,
    },
  });
  if (error) throw new Error(`request-activation-link: ${error.message}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args    = process.argv.slice(2);
  const mode: Mode =
    args.includes('--migrate') ? 'migrate' :
    args.includes('--dry-run') ? 'dry-run' :
    'preview';

  const get = (flag: string) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : null; };

  const xlsxPath      = get('--xlsx');
  const progressSheet = get('--progress-sheet');
  const statusSheet   = get('--status-sheet')   ?? 'Status';
  const scoreSheet      = get('--score-sheet')      ?? 'Score';
  const businessLineCol = get('--business-line-col') ?? 'Business Line';

  if (!xlsxPath || !progressSheet) {
    console.error([
      'Usage: migrate-psybersafe-users.ts',
      '  --xlsx <file.xlsx>',
      '  --progress-sheet <sheetName>    e.g. 20251230',
      '  [--status-sheet <sheetName>]    default: Status',
      '  [--score-sheet  <sheetName>]    default: Score',
      '  [--dry-run | --migrate]',
    ].join('\n'));
    process.exit(1);
  }

  const supabaseUrl    = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const appBaseUrl     = (process.env.APP_BASE_URL || '').replace(/\/$/, '');
  const clientPath     = process.env.CLIENT_PATH || '';

  if (!supabaseUrl || !serviceRoleKey) {
    console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY environment variables.');
    process.exit(1);
  }
  if (mode !== 'preview' && !appBaseUrl) {
    console.error('Set APP_BASE_URL environment variable (e.g. https://staysecure-learn.raynsecure.com).');
    process.exit(1);
  }

  await preflight(mode, xlsxPath, statusSheet, scoreSheet, progressSheet);

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── Load workbook ─────────────────────────────────────────────────────────
  console.log(`📂 Loading workbook: ${xlsxPath}`);
  const wb = XLSX.readFile(path.resolve(xlsxPath));
  console.log(`   Sheets found: ${wb.SheetNames.join(', ')}`);

  const statusRows   = readSheet<StatusRow>(wb, statusSheet);
  const scoreRows    = readSheet<ScoreRow>(wb, scoreSheet);
  const progressRows = readSheet<ProgressRow>(wb, progressSheet);

  console.log(`   "${statusSheet}" sheet:   ${statusRows.length} users`);
  console.log(`   "${scoreSheet}" sheet:    ${scoreRows.length} quiz results`);
  console.log(`   "${progressSheet}" sheet: ${progressRows.length} learner rows`);

  // ── Build lookup maps ─────────────────────────────────────────────────────

  // Score sheet: Fullname (lowercase) → email  (name→email bridge)
  const nameToEmail = new Map<string, string>();
  // Score sheet: email (lowercase) → quiz Result
  const emailToQuizScore = new Map<string, number | null>();
  for (const row of scoreRows) {
    if (!row.Email) continue;
    const email = String(row.Email).toLowerCase().trim();
    const name  = String(row.Fullname || '').toLowerCase().trim();
    if (name)  nameToEmail.set(name, email);
    emailToQuizScore.set(email, parseScore(row.Result));
  }

  // Progress sheet: learner name (lowercase) → row
  const progressByName = new Map<string, ProgressRow>();
  for (const row of progressRows) {
    if (!row.Learner) continue;
    progressByName.set(String(row.Learner).toLowerCase().trim(), row);
  }

  // ── Classify users ────────────────────────────────────────────────────────
  const migrations: UserMigration[] = statusRows
    .filter((r) => r.Email)
    .map((r) => {
      const email     = String(r.Email).toLowerCase().trim();
      const firstName = String(r['First Name'] || '').trim();
      const lastName  = String(r['Last Name']  || '').trim();
      const fullName  = `${firstName} ${lastName}`.trim();

      // Find progress row: try exact name match, then Score sheet Fullname
      const progressRow =
        progressByName.get(fullName.toLowerCase()) ??
        progressByName.get((nameToEmail.get(fullName.toLowerCase()) ? fullName.toLowerCase() : ''));

      const scoreSheetScore = emailToQuizScore.get(email) ?? null;
      const { cohort, episodesCompleted, quizScore } = classifyUser(progressRow, scoreSheetScore);

      // Business line: check Status sheet first, fall back to progress sheet
      const businessLine =
        String(r[businessLineCol] || '').trim() ||
        (progressRow ? String(progressRow[businessLineCol] || '').trim() : '') ||
        undefined;

      return { email, fullName, firstName, lastName, cohort, episodesCompleted, quizScore, businessLine };
    });

  // ── Summary ───────────────────────────────────────────────────────────────
  const counts = { E1: 0, E2: 0, E3: 0 };
  for (const m of migrations) counts[m.cohort]++;

  // Warn about unmatched users (in Status but not in progress sheet)
  const unmatched = migrations.filter((m) => m.episodesCompleted === 0 && !progressByName.has(m.fullName.toLowerCase()));
  if (unmatched.length > 0) {
    console.log(`\n⚠️  ${unmatched.length} users not found in progress sheet (likely Pending/no progress — assigned E1):`);
    unmatched.slice(0, 10).forEach((m) => console.log(`   ${m.fullName} <${m.email}>`));
    if (unmatched.length > 10) console.log(`   ... and ${unmatched.length - 10} more`);
  }

  console.log('\n📊 Classification summary:');
  console.log(`   E1 → Cybersecurity Foundation (clean slate):        ${counts.E1}`);
  console.log(`   E2 → Cybersecurity Foundation II (continue):        ${counts.E2}`);
  console.log(`   E3 → Foundation (completed) + Intermediate (new):   ${counts.E3}`);
  console.log(`   Total: ${migrations.length}`);

  const printCohort = (label: string, cohort: Cohort, max: number) => {
    const group = migrations.filter((m) => m.cohort === cohort);
    if (group.length === 0) return;
    console.log(`\n   ${label} (${group.length} users):`);
    group.slice(0, max).forEach((m) =>
      console.log(`   [${m.cohort}] ${m.email.padEnd(40)}  episodes=${m.episodesCompleted}  score=${m.quizScore ?? 'N/A'}`)
    );
    if (group.length > max) console.log(`   ... and ${group.length - max} more`);
  };

  printCohort('E1 — Cybersecurity Foundation', 'E1', counts.E1); // show all E1
  printCohort('E2 — Cybersecurity Foundation II', 'E2', counts.E2); // show all E2
  printCohort('E3 — Foundation completed + Intermediate', 'E3', 20); // cap E3 at 20

  // Business line / department distribution
  const blCounts = new Map<string, number>();
  for (const m of migrations) {
    const bl = m.businessLine ?? '(none)';
    blCounts.set(bl, (blCounts.get(bl) ?? 0) + 1);
  }
  const hasBusinessLines = blCounts.size > 1 || !blCounts.has('(none)');
  if (hasBusinessLines) {
    console.log('\n📋 Departments (from Business Line column):');
    for (const [bl, count] of [...blCounts.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      console.log(`   ${bl.padEnd(55)} ${count}`);
    }
  } else {
    console.log(`\n   ℹ️  No "${businessLineCol}" column found — department assignment will be skipped.`);
  }

  // ── Validate tracks exist (runs in all modes including preview) ──────────
  console.log('\n📚 Validating tracks and lessons in target DB...');
  const { data: foundationLessons, error: lessonsError } = await supabase
    .from('learning_track_lessons')
    .select('lesson_id, order_index')
    .eq('learning_track_id', TRACK_IDS.cybersecurityFoundation)
    .order('order_index');
  if (lessonsError) throw new Error(`learning_track_lessons fetch: ${lessonsError.message}`);
  console.log(`   Foundation track: ${foundationLessons?.length ?? 0} lessons`);
  if (!foundationLessons?.length) {
    console.warn('   ⚠️  No lessons found in Foundation track — run SyncManager before migrating users.');
  }

  if (mode === 'preview') {
    console.log('\n✅ Preview complete. Run with --dry-run to create users and write records.');
    return;
  }

  // ── Sync departments (create any that don't exist yet) ────────────────────
  let departmentMap = new Map<string, string>(); // businessLine (lowercase) → department UUID
  if (hasBusinessLines) {
    const uniqueBusinessLines = [...new Set(
      migrations.map((m) => m.businessLine).filter((bl): bl is string => !!bl)
    )];
    console.log(`\n🏢 Syncing ${uniqueBusinessLines.length} department(s)...`);
    departmentMap = await syncDepartments(supabase, uniqueBusinessLines);
    console.log(`   ${departmentMap.size} department(s) ready.`);
  }

  // ── Create users + write records ──────────────────────────────────────────

  // Sort by cohort so output groups match the classification summary
  migrations.sort((a, b) => a.cohort.localeCompare(b.cohort));

  console.log(`\n🔄 Processing ${migrations.length} users  (E1: ${counts.E1}  E2: ${counts.E2}  E3: ${counts.E3})\n`);

  const now = new Date().toISOString();
  let created = 0, alreadyExisted = 0, recordsWritten = 0, emailsSent = 0;
  let createErrors = 0, recordErrors = 0, emailErrors = 0;

  const cohortCounters: Record<Cohort, number> = { E1: 0, E2: 0, E3: 0 };
  let currentCohort: Cohort | null = null;

  for (const m of migrations) {
    // Print a section header whenever the cohort changes
    if (m.cohort !== currentCohort) {
      currentCohort = m.cohort;
      const labels: Record<Cohort, string> = {
        E1: 'Cybersecurity Foundation (clean slate)',
        E2: 'Cybersecurity Foundation II (continue)',
        E3: 'Foundation completed + Intermediate',
      };
      console.log(`\n   ── ${m.cohort}: ${labels[m.cohort]} (${counts[m.cohort]} users) ──`);
    }

    cohortCounters[m.cohort]++;
    const tag = `${m.cohort} ${String(cohortCounters[m.cohort]).padStart(2)}/${counts[m.cohort]}`;

    const result = await createUser(supabase, serviceRoleKey!, m, clientPath, appBaseUrl);

    let userId: string | undefined;

    if (result === 'already_exists') {
      alreadyExisted++;
      const { data } = await supabase.from('profiles').select('id').eq('email', m.email).maybeSingle();
      userId = data?.id;
    } else if (result === null) {
      createErrors++;
      console.log(`   [${tag}]  ✗ ${m.email}  (user creation failed)`);
      continue;
    } else {
      created++;
      userId = result ?? undefined;
      await new Promise((r) => setTimeout(r, 600));
      if (!userId) {
        const { data } = await supabase.from('profiles').select('id').eq('email', m.email).maybeSingle();
        userId = data?.id;
      }
    }

    if (!userId) {
      console.log(`   [${tag}]  ✗ ${m.email}  (could not resolve user ID)`);
      recordErrors++;
      continue;
    }

    m.userId = userId;

    try {
      if (m.cohort === 'E1') {
        await writeE1(supabase, userId, now);
      } else if (m.cohort === 'E2') {
        await writeE2(supabase, userId, now);
      } else {
        await writeE3(supabase, userId, now, foundationLessons ?? []);
      }
      recordsWritten++;

      // Assign department if a business line was mapped
      let deptNote = '';
      if (departmentMap.size > 0) {
        if (!m.businessLine) {
          // Column exists in sheet but this user's cell is blank
          deptNote = `  dept=(none)`;
        } else {
          const deptId = departmentMap.get(m.businessLine.toLowerCase());
          if (deptId) {
            try {
              await assignDepartment(supabase, userId, deptId, now);
              deptNote = `  dept=✓`;
            } catch (err) {
              deptNote = `  dept=✗`;
              console.warn(`   ⚠️  ${m.email} (dept): ${err instanceof Error ? err.message : err}`);
            }
          } else {
            // Business line value present but not in the synced map — shouldn't happen
            deptNote = `  dept=? ("${m.businessLine}")`;
          }
        }
      }

      const userLabel = result === 'already_exists' ? 'existed' : 'created';
      console.log(`   [${tag}]  ✓ ${m.email}  (${userLabel})${deptNote}`);
    } catch (err) {
      recordErrors++;
      console.log(`   [${tag}]  ✗ ${m.email}  (records: ${err instanceof Error ? err.message : err})`);
      continue;
    }

    if (mode === 'migrate') {
      try {
        await sendActivationEmail(supabase, serviceRoleKey!, m.email, appBaseUrl, clientPath);
        emailsSent++;
      } catch (err) {
        emailErrors++;
        console.error(`   ✗ ${m.email} (email): ${err instanceof Error ? err.message : err}`);
      }
    }
  }

  // ── Final report ──────────────────────────────────────────────────────────
  console.log(`\n${'─'.repeat(60)}`);
  console.log(`✅ Done.`);
  console.log(`   Users created:         ${created}`);
  console.log(`   Users already existed: ${alreadyExisted}`);
  console.log(`   Records written:       ${recordsWritten}`);
  if (mode === 'migrate') {
    console.log(`   Activation emails:     ${emailsSent}`);
    if (emailErrors > 0) console.warn(`   Email errors:          ${emailErrors}`);
  } else {
    console.log(`\n   ℹ️  No activation emails sent (--dry-run).`);
    console.log(`   Run with --migrate to send activation emails.`);
  }
  if (createErrors > 0) console.warn(`   User creation errors:  ${createErrors}`);
  if (recordErrors > 0) console.warn(`   Record errors:         ${recordErrors}`);
}

// ---------------------------------------------------------------------------
// Department sync — creates missing departments, returns name→id map
// ---------------------------------------------------------------------------

async function syncDepartments(
  supabase: any,
  businessLines: string[],
): Promise<Map<string, string>> {
  if (businessLines.length === 0) return new Map();

  // Upsert each department by name (unique constraint: departments_name_key)
  for (const name of businessLines) {
    const { error } = await supabase
      .from('departments')
      .upsert({ name }, { onConflict: 'name', ignoreDuplicates: true });
    if (error) console.warn(`   ⚠️  Department upsert failed for "${name}": ${error.message}`);
  }

  // Fetch IDs for all names (including ones that already existed)
  const { data, error } = await supabase
    .from('departments')
    .select('id, name')
    .in('name', businessLines);
  if (error) throw new Error(`department fetch: ${error.message}`);

  const map = new Map<string, string>();
  for (const dept of data ?? []) {
    map.set((dept.name as string).toLowerCase(), dept.id as string);
  }
  return map;
}

// ---------------------------------------------------------------------------
// Per-cohort writers
// ---------------------------------------------------------------------------

async function writeE1(supabase: any, userId: string, now: string) {
  await upsertAssignment(supabase, userId, TRACK_IDS.cybersecurityFoundation, now);
  await upsertTrackProgress(supabase, userId, TRACK_IDS.cybersecurityFoundation, { enrolled_at: now });
}

async function writeE2(supabase: any, userId: string, now: string) {
  await upsertAssignment(supabase, userId, TRACK_IDS.cybersecurityFoundationII, now);
  await upsertTrackProgress(supabase, userId, TRACK_IDS.cybersecurityFoundationII, { enrolled_at: now });
}

async function writeE3(
  supabase: any,
  userId: string,
  now: string,
  foundationLessons: { lesson_id: string; order_index: number }[]
) {
  await upsertAssignment(supabase, userId, TRACK_IDS.cybersecurityFoundation, now);
  await upsertTrackProgress(supabase, userId, TRACK_IDS.cybersecurityFoundation, {
    enrolled_at:          now,
    started_at:           now,
    completed_at:         now,
    progress_percentage:  100,
    current_lesson_order: foundationLessons.length,
  });
  for (const { lesson_id } of foundationLessons) {
    await upsertLessonProgress(supabase, userId, lesson_id, now);
  }
  await upsertAssignment(supabase, userId, TRACK_IDS.cybersecurityIntermediate, now);
  await upsertTrackProgress(supabase, userId, TRACK_IDS.cybersecurityIntermediate, { enrolled_at: now });
  await issueCertificate(supabase, userId, now);
}

// ---------------------------------------------------------------------------
// DB helpers — all upsert so the script is idempotent
// ---------------------------------------------------------------------------

async function assignDepartment(supabase: any, userId: string, departmentId: string, now: string) {
  const { error } = await supabase
    .from('user_departments')
    .upsert(
      { user_id: userId, department_id: departmentId, assigned_at: now, is_primary: true },
      { onConflict: 'user_id,department_id', ignoreDuplicates: true },
    );
  if (error) throw new Error(`department assignment: ${error.message}`);
}

async function upsertAssignment(supabase: any, userId: string, trackId: string, now: string) {
  const { error } = await supabase
    .from('learning_track_assignments')
    .upsert(
      { user_id: userId, learning_track_id: trackId, assigned_at: now, status: 'assigned', completion_required: true, notes: 'Migrated from Psybersafe' },
      { onConflict: 'user_id,learning_track_id', ignoreDuplicates: true }
    );
  if (error) throw new Error(`assignment upsert: ${error.message}`);
}

async function upsertTrackProgress(
  supabase: any,
  userId: string,
  trackId: string,
  fields: { enrolled_at: string; started_at?: string; completed_at?: string; progress_percentage?: number; current_lesson_order?: number }
) {
  const { error } = await supabase
    .from('user_learning_track_progress')
    .upsert(
      { user_id: userId, learning_track_id: trackId, ...fields },
      { onConflict: 'user_id,learning_track_id', ignoreDuplicates: false }
    );
  if (error) throw new Error(`track progress upsert: ${error.message}`);
}

async function upsertLessonProgress(supabase: any, userId: string, lessonId: string, now: string) {
  const { error } = await supabase
    .from('user_lesson_progress')
    .upsert(
      { user_id: userId, lesson_id: lessonId, completed_at: now, started_at: now, last_accessed: now, completed_nodes: [] },
      { onConflict: 'user_id,lesson_id', ignoreDuplicates: true }
    );
  if (error) throw new Error(`lesson progress upsert: ${error.message}`);
}

async function issueCertificate(supabase: any, userId: string, now: string) {
  const { data: existing } = await supabase
    .from('certificates')
    .select('id')
    .eq('user_id', userId)
    .eq('name', CERTIFICATE_NAME)
    .maybeSingle();
  if (existing) return;

  const credentialId = `CERT-${Date.now()}-${Math.random().toString(36).slice(2, 9).toUpperCase()}`;
  const { data: cert, error: certError } = await supabase
    .from('certificates')
    .insert({
      user_id: userId, name: CERTIFICATE_NAME, type: CERTIFICATE_TYPE,
      issued_by: CERTIFICATE_ISSUER, date_acquired: now, status: 'Valid',
      org_cert: false, credential_id: credentialId,
    })
    .select('id')
    .single();
  if (certError) throw new Error(`certificate insert: ${certError.message}`);

  supabase.functions
    .invoke('generate-certificate', { body: { certificate_id: cert.id } })
    .catch((err: Error) =>
      console.warn(`   ⚠️  generate-certificate failed for user ${userId}: ${err.message}`)
    );
}

main().catch((err) => {
  console.error('\n❌ Fatal error:', err);
  process.exit(1);
});
