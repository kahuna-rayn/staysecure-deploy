#!/usr/bin/env node
/**
 * Test all notification templates by invoking the test-send-notification Edge Function.
 * Queries all enabled notification_rules and tests each one.
 *
 * Usage (from learn/):
 *   node scripts/test-notification-variables.mjs \
 *     --user    <user_id> \
 *     --lesson  <lesson_id> \
 *     --quiz    <quiz_lesson_id> \
 *     --track   <learning_track_id>   (optional — fetched from DB if omitted) \
 *     --cert    <certificate_id>      (optional — fetched from DB if omitted) \
 *     --event   <trigger_event>       (optional — test one event only)
 *
 * Reads credentials from .env.local automatically.
 */

// ---------------------------------------------------------------------------
// Load .env.local
// ---------------------------------------------------------------------------
import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const envPath = resolve(__dirname, '../.env.local');
try {
  const lines = readFileSync(envPath, 'utf8').split('\n');
  for (const line of lines) {
    const match = line.match(/^([^=]+)=(.*)$/);
    if (!match) continue;
    const key = match[1].trim();
    const val = match[2].trim().replace(/^(['"])(.*)\1$/s, '$2');
    if (!process.env[key]) process.env[key] = val;
  }
} catch { /* rely on env vars already set */ }

// ---------------------------------------------------------------------------
// Parse CLI args
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const get = (flag) => { const i = args.indexOf(flag); return i !== -1 ? args[i + 1] : undefined; };

const userId          = get('--user');
const lessonId        = get('--lesson');
const quizLessonId    = get('--quiz');
const learningTrackId = get('--track');
const certificateId   = get('--cert');
const singleEvent     = get('--event');

if (!userId) {
  console.error('Usage: node test-notification-variables.mjs --user <id> --lesson <id> [--quiz <id>] [--track <id>] [--cert <id>] [--event <type>]');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Supabase setup
// ---------------------------------------------------------------------------
let supabaseUrl;
const clientConfigs = process.env.VITE_CLIENT_CONFIGS;
if (clientConfigs) {
  const parsed = JSON.parse(clientConfigs);
  supabaseUrl = (parsed.default || Object.values(parsed)[0])?.supabaseUrl;
} else {
  supabaseUrl = process.env.VITE_SUPABASE_URL;
}
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl) { console.error('Missing VITE_CLIENT_CONFIGS or VITE_SUPABASE_URL'); process.exit(1); }
if (!serviceRoleKey) { console.error('Missing SUPABASE_SERVICE_ROLE_KEY'); process.exit(1); }

const { createClient } = await import('@supabase/supabase-js');
const supabase = createClient(supabaseUrl, serviceRoleKey);

// ---------------------------------------------------------------------------
// Auto-discover a learning_track_id and certificate_id if not provided
// ---------------------------------------------------------------------------
let resolvedTrackId = learningTrackId;
let resolvedCertId  = certificateId;

if (!resolvedTrackId) {
  const { data } = await supabase.from('learning_tracks').select('id, title').limit(1).maybeSingle();
  if (data) { resolvedTrackId = data.id; console.log(`ℹ️  Auto-selected track: "${data.title}" (${data.id})`); }
}

if (!resolvedCertId) {
  const { data } = await supabase.from('certificates').select('id, name').eq('user_id', userId).limit(1).maybeSingle();
  if (data) { resolvedCertId = data.id; console.log(`ℹ️  Auto-selected certificate: "${data.name}" (${data.id})`); }
}

// ---------------------------------------------------------------------------
// Fetch all enabled notification rules (or just the requested one)
// ---------------------------------------------------------------------------
let rulesQuery = supabase.from('notification_rules').select('trigger_event, name').eq('is_enabled', true).order('trigger_event');
if (singleEvent) rulesQuery = rulesQuery.eq('trigger_event', singleEvent);
const { data: rules, error: rulesErr } = await rulesQuery;

if (rulesErr || !rules?.length) {
  console.error('No enabled notification rules found:', rulesErr?.message);
  process.exit(1);
}

console.log(`\nTesting ${rules.length} notification rule(s)...\n`);

// ---------------------------------------------------------------------------
// Map each event type to the right context IDs
// ---------------------------------------------------------------------------
const contextForEvent = (event) => {
  const ctx = { trigger_event: event, user_id: userId };

  if (['lesson_completed', 'lesson_reminder'].includes(event)) {
    ctx.lesson_id = lessonId;
    ctx.learning_track_id = resolvedTrackId;
  }

  if (['track_completed', 'track_milestone_50'].includes(event)) {
    ctx.learning_track_id = resolvedTrackId;
    // Runtime variables computed from user_lesson_progress in the real app
    ctx.test_overrides = { time_spent_hours: '1.5' };
  }

  if (event === 'quiz_high_score') {
    ctx.lesson_id = quizLessonId || lessonId;
    // Runtime variables passed from quiz result in the real app
    ctx.test_overrides = {
      score: '92',
      correct_answers: '11',
      total_questions: '12',
    };
  }

  if (['achievement_unlocked', 'certificate_expiry', 'certificate_awarded'].includes(event)) {
    ctx.certificate_id = resolvedCertId;
  }

  if (event === 'manager_employee_incomplete') {
    ctx.lesson_id = lessonId;
    ctx.learning_track_id = resolvedTrackId;
    // Variables built by the manager Edge Function from employee/reminder data
    ctx.test_overrides = {
      manager_name: '(manager name)',
      employee_name: '(employee name)',
      employee_email: 'employee@example.com',
      reminder_attempts: 3,
      multiple_attempts: true,
      due_date: '',
      total_incomplete_count: 2,
      incomplete_lessons: [
        { lesson_title: 'Phishing Awareness', learning_track_title: 'Cybersecurity Foundation', due_date: '' },
        { lesson_title: 'Password Security', learning_track_title: 'Cybersecurity Foundation', due_date: '' },
      ],
    };
  }

  return ctx;
};

// ---------------------------------------------------------------------------
// Run each rule
// ---------------------------------------------------------------------------
const HR = '─'.repeat(62);
const results = [];

for (const rule of rules) {
  const body = contextForEvent(rule.trigger_event);
  process.stdout.write(`${HR}\n${rule.name} (${rule.trigger_event})\n${HR}\n`);

  const res = await fetch(`${supabaseUrl}/functions/v1/test-send-notification`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${serviceRoleKey}` },
    body: JSON.stringify(body),
  });
  const result = await res.json();

  if (result.error) {
    console.log(`  ❌ Error: ${result.error}`);
    results.push({ event: rule.trigger_event, ok: false, reason: result.error });
    continue;
  }

  // Print resolved variables
  if (result.variables) {
    Object.entries(result.variables).forEach(([k, v]) => console.log(`  ${k}: "${v}"`));
  }

  // Print unresolved
  if (result.unresolved_variables?.length) {
    console.log(`\n  ⚠️  Unresolved: ${result.unresolved_variables.map(v => `{{${v}}}`).join(', ')}`);
  }

  const ok = result.success && !result.unresolved_variables?.length;
  console.log(`\n  ${result.success ? '✅' : '❌'} ${result.success ? `Email sent to ${result.recipient}` : 'Send failed'}`);
  if (result.subject) console.log(`  Subject: "${result.subject}"`);

  results.push({
    event: rule.trigger_event,
    ok,
    sent: result.success,
    unresolved: result.unresolved_variables || [],
  });
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
console.log(`\n${HR}`);
console.log('Summary');
console.log(HR);
for (const r of results) {
  const icon = r.sent ? (r.unresolved.length ? '⚠️ ' : '✅') : '❌';
  const detail = r.sent
    ? (r.unresolved.length ? `sent but ${r.unresolved.length} unresolved: ${r.unresolved.join(', ')}` : 'all variables resolved')
    : (r.reason || 'send failed');
  console.log(`  ${icon} ${r.event.padEnd(35)} ${detail}`);
}

const allOk = results.every(r => r.sent);
process.exit(allOk ? 0 : 1);
