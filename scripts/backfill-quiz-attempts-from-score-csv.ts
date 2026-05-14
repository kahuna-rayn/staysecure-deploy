#!/usr/bin/env npx ts-node
/**
 * Backfill public.quiz_attempts from a Score export CSV (multiple rows per user =
 * multiple attempts), e.g. organisation_Ren_Ci.csv with columns:
 *   Email, Result, DateSubmitted, SubmissionId (others ignored)
 *
 * Scores are interpreted like migrate-psybersafe-users.ts: Result out of 20,
 * pass >= 16 → percentage >= 80%.
 *
 * Usage (from deploy/scripts):
 *
 *   npx ts-node backfill-quiz-attempts-from-score-csv.ts \
 *     --csv "/path/to/organisation_Ren_Ci.csv"
 *
 * Preview only (default): prints summary, no DB writes.
 *
 *   npx ts-node backfill-quiz-attempts-from-score-csv.ts \
 *     --csv "/path/to/file.csv" --apply --replace-lesson
 *
 * --replace-lesson  Deletes existing quiz_attempts for the resolved quiz lesson
 *                   for every user_id that appears in the CSV, then inserts
 *                   fresh rows (recommended after a synthetic single-attempt backfill).
 *
 * Optional:
 *   --lesson-id <uuid>           Skip auto-resolve; use this lesson_id directly.
 *   --foundation-track-id <uuid> Default: synced Cybersecurity Foundation id (see migrate script).
 *   --total-questions <n>        Default 20.
 *   --pass-at-least <n>          Default 16 correct answers = pass.
 *
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (same .env loading as migrate-psybersafe-users.ts)
 */

import * as fs from 'fs';
import * as path from 'path';
import { createClient } from '@supabase/supabase-js';
import * as XLSX from 'xlsx';

(function loadEnv() {
  const parseFile = (file: string) => {
    if (!fs.existsSync(file)) return false;
    const lines = fs.readFileSync(file, 'utf-8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim().replace(/^export\s+/, '');
      const val = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      process.env[key] = val;
    }
    console.log(`📄 Loaded env from ${file}`);
    return true;
  };

  parseFile(path.resolve(__dirname, '.env')) || parseFile(path.resolve(__dirname, '..', '.env'));
})();

/** Same UUID as migrate-psybersafe-users.ts — Lesson Sync */
const DEFAULT_FOUNDATION_TRACK_ID = '3a0a6b51-0108-4b22-83c5-eb258486d7c8';

function getFlag(args: string[], name: string): string | null {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] ?? null : null;
}

function hasFlag(args: string[], name: string): boolean {
  return args.includes(name);
}

function parseScore(raw: unknown): number | null {
  if (raw === null || raw === undefined || raw === '') return null;
  if (typeof raw === 'number' && !Number.isNaN(raw)) return raw;
  const s = String(raw).trim();
  if (s === '' || s === '#N/A' || s === '-') return null;
  const n = parseFloat(s);
  return Number.isNaN(n) ? null : n;
}

function normEmail(raw: unknown): string | null {
  if (raw === null || raw === undefined) return null;
  const s = String(raw).trim().toLowerCase();
  return s || null;
}

function parseSubmittedAt(raw: unknown): string {
  if (raw === null || raw === undefined || raw === '') return new Date().toISOString();
  const s = String(raw).trim();
  const d = new Date(s);
  if (!Number.isNaN(d.getTime())) return d.toISOString();
  return new Date().toISOString();
}

type CsvRow = Record<string, unknown>;

function rowEmail(r: CsvRow): string | null {
  return normEmail(r.Email ?? r.email ?? r['Email']);
}

function rowResult(r: CsvRow): number | null {
  return parseScore(r.Result ?? r.result ?? r['Result']);
}

function rowSubmitted(r: CsvRow): string {
  return parseSubmittedAt(r.DateSubmitted ?? r.dateSubmitted ?? r['Date Submitted']);
}

function rowSubmissionKey(r: CsvRow): number {
  const sid = r.SubmissionId ?? r.submissionId ?? r['Submission Id'];
  const n = typeof sid === 'number' ? sid : parseInt(String(sid ?? '0'), 10);
  return Number.isNaN(n) ? 0 : n;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function resolveCapstoneQuizLessonId(supabase: any, trackId: string): Promise<string> {
  const { data: links, error: e1 } = await supabase
    .from('learning_track_lessons')
    .select('lesson_id, order_index')
    .eq('learning_track_id', trackId)
    .order('order_index', { ascending: true });
  if (e1) throw new Error(`learning_track_lessons: ${e1.message}`);
  if (!links?.length) throw new Error('No lessons on Foundation track — sync content first.');

  const typedLinks = links as Array<{ lesson_id: string; order_index: number }>;
  const ids = typedLinks.map((l) => l.lesson_id);
  const { data: lessons, error: e2 } = await supabase
    .from('lessons')
    .select('id, lesson_type, title')
    .in('id', ids)
    .eq('lesson_type', 'quiz');
  if (e2) throw new Error(`lessons: ${e2.message}`);
  const lessonRows = (lessons ?? []) as Array<{ id: string; lesson_type: string; title: string }>;
  const quizIds = new Set(lessonRows.map((l) => l.id));
  const quizzesOnTrack = typedLinks.filter((l) => quizIds.has(l.lesson_id));
  if (quizzesOnTrack.length === 0) {
    throw new Error('No quiz-type lesson found on Cybersecurity Foundation track.');
  }
  // Capstone: highest order_index among quizzes (e.g. "Go Phish!")
  quizzesOnTrack.sort((a, b) => b.order_index - a.order_index);
  const picked = quizzesOnTrack[0].lesson_id;
  const meta = lessonRows.find((l) => l.id === picked);
  console.log(
    `   Resolved quiz lesson: ${picked}  (${meta?.title ?? 'unknown title'}, order on track among quizzes = capstone)`,
  );
  return picked;
}

async function main() {
  const args = process.argv.slice(2);
  const csvPath = getFlag(args, '--csv');
  const apply = hasFlag(args, '--apply');
  const replaceLesson = hasFlag(args, '--replace-lesson');
  const lessonIdArg = getFlag(args, '--lesson-id');
  const foundationTrackId = getFlag(args, '--foundation-track-id') ?? DEFAULT_FOUNDATION_TRACK_ID;
  const totalQuestions = parseInt(getFlag(args, '--total-questions') ?? '20', 10);
  const passAtLeast = parseInt(getFlag(args, '--pass-at-least') ?? '16', 10);

  if (!csvPath || !fs.existsSync(path.resolve(csvPath))) {
    console.error(
      [
        'Usage: npx ts-node backfill-quiz-attempts-from-score-csv.ts --csv <file.csv>',
        '  [--apply] [--replace-lesson] [--lesson-id <uuid>] [--foundation-track-id <uuid>]',
        '  [--total-questions 20] [--pass-at-least 16]',
      ].join('\n'),
    );
    process.exit(1);
  }

  const abs = path.resolve(csvPath);
  console.log(`📂 Reading CSV: ${abs}`);
  const wb = XLSX.readFile(abs, { type: 'binary', raw: false });
  const sheetName = wb.SheetNames[0];
  const ws = wb.Sheets[sheetName];
  const rows = XLSX.utils.sheet_to_json<CsvRow>(ws, { defval: '' });
  console.log(`   Rows: ${rows.length} (sheet "${sheetName}")`);

  type Submission = { email: string; correct: number; submittedIso: string; submissionKey: number };
  const byEmail = new Map<string, Submission[]>();

  for (const r of rows) {
    const email = rowEmail(r);
    const correctRaw = rowResult(r);
    if (!email || correctRaw === null) continue;
    const correct = Math.max(0, Math.min(totalQuestions, Math.round(correctRaw)));
    const sub: Submission = {
      email,
      correct,
      submittedIso: rowSubmitted(r),
      submissionKey: rowSubmissionKey(r),
    };
    if (!byEmail.has(email)) byEmail.set(email, []);
    byEmail.get(email)!.push(sub);
  }

  byEmail.forEach((list) => {
    list.sort((a, b) => {
      const ta = new Date(a.submittedIso).getTime();
      const tb = new Date(b.submittedIso).getTime();
      if (ta !== tb) return ta - tb;
      return a.submissionKey - b.submissionKey;
    });
  });

  console.log(`   Distinct emails with ≥1 scored row: ${byEmail.size}`);
  let attemptTotal = 0;
  byEmail.forEach((list) => {
    attemptTotal += list.length;
  });
  console.log(`   Total submissions (attempt rows to insert): ${attemptTotal}`);

  if (!apply) {
    console.log(
      '\n✅ Preview only (CSV parsed — no DB calls). Set SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY and run with --apply [--replace-lesson] to insert quiz_attempts.',
    );
    process.exit(0);
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.');
    process.exit(1);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  const quizLessonId = lessonIdArg ?? (await resolveCapstoneQuizLessonId(supabase, foundationTrackId));

  const emails = Array.from(byEmail.keys());
  const { data: profiles, error: pe } = await supabase.from('profiles').select('id, email').in('email', emails);
  if (pe) throw new Error(`profiles: ${pe.message}`);

  const emailToUserId = new Map<string, string>();
  for (const p of profiles ?? []) {
    const em = normEmail((p as { email?: string }).email);
    const id = (p as { id: string }).id;
    if (em && id) emailToUserId.set(em, id);
  }

  const missing = emails.filter((e) => !emailToUserId.has(e));
  if (missing.length) {
    console.warn(`   ⚠️  No profile for ${missing.length} email(s) (skipped). Example: ${missing.slice(0, 5).join(', ')}`);
  }

  const userIdsToTouch = Array.from(
    new Set(emails.filter((e) => emailToUserId.has(e)).map((e) => emailToUserId.get(e)!)),
  );

  if (!apply) {
    console.log('\n✅ Preview only. Re-run with --apply (and usually --replace-lesson) to write quiz_attempts.');
    process.exit(0);
  }

  if (replaceLesson && userIdsToTouch.length > 0) {
    console.log(`\n🗑️  Deleting existing quiz_attempts for lesson ${quizLessonId} (${userIdsToTouch.length} users)...`);
    const chunk = 100;
    for (let i = 0; i < userIdsToTouch.length; i += chunk) {
      const part = userIdsToTouch.slice(i, i + chunk);
      const { error } = await supabase.from('quiz_attempts').delete().eq('lesson_id', quizLessonId).in('user_id', part);
      if (error) throw new Error(`delete quiz_attempts: ${error.message}`);
    }
  }

  let inserted = 0;

  for (const email of emails) {
    const userId = emailToUserId.get(email);
    if (!userId) continue;
    const subs = byEmail.get(email)!;
    let attemptNo = 1;
    for (const sub of subs) {
      const pct = Math.round((sub.correct / totalQuestions) * 100);
      const passed = sub.correct >= passAtLeast;
      const { error } = await supabase.from('quiz_attempts').insert({
        user_id: userId,
        lesson_id: quizLessonId,
        attempt_number: attemptNo,
        total_questions: totalQuestions,
        correct_answers: sub.correct,
        percentage_score: pct,
        passed,
        completed_at: sub.submittedIso,
        answers_data: [],
      });
      if (error) {
        if (error.code === '23505' && !replaceLesson) {
          console.warn(`   ⚠️  Conflict ${email} attempt ${attemptNo}: ${error.message} — use --replace-lesson`);
          break;
        }
        throw new Error(`insert ${email} #${attemptNo}: ${error.message}`);
      }
      inserted++;
      attemptNo++;
    }
  }

  const noProfile = emails.filter((e) => !emailToUserId.has(e)).length;
  console.log(`\n✅ Done. Inserted ${inserted} quiz_attempt row(s). CSV emails with no matching profile: ${noProfile}.`);
}

main().catch((err) => {
  console.error('❌', err instanceof Error ? err.message : err);
  process.exit(1);
});
