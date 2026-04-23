#!/usr/bin/env node
/**
 * Check activation "user exists" query as the app does it (anon key only).
 * If the profile exists in the DB but this script returns no row, RLS is
 * hiding the row from anon — which causes "not registered" on the activation page.
 *
 * Usage:
 *   From learn/ with env vars set (e.g. from secrets/dev-secrets.env):
 *     source secrets/dev-secrets.env  # or export manually
 *     node scripts/check-activation-rls.mjs [email]
 *
 *   Or inline:
 *     VITE_SUPABASE_URL=https://xxx.supabase.co VITE_SUPABASE_ANON_KEY=eyJ... node scripts/check-activation-rls.mjs sasi@raynsecure.com
 *
 * Uses VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (same as the app).
 */

import { createClient } from '@supabase/supabase-js';

const email = process.argv[2] || 'sasi@raynsecure.com';
const url = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL;
const anonKey = process.env.VITE_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  console.error('Missing env: set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (or SUPABASE_URL / SUPABASE_ANON_KEY)');
  console.error('Example: source secrets/dev-secrets.env && node scripts/check-activation-rls.mjs', email);
  process.exit(1);
}

const supabase = createClient(url, anonKey);

console.log('Querying profiles with ANON key (same as activation page)...');
console.log('Email:', email);

const { data: profile, error } = await supabase
  .from('profiles')
  .select('id, email, full_name')
  .eq('email', email)
  .maybeSingle();

if (error) {
  console.error('Query error:', error.message);
  process.exit(1);
}

if (profile) {
  console.log('Result: ROW FOUND (anon can see this profile — RLS is not blocking)');
  console.log(profile);
} else {
  console.log('Result: NO ROW (anon cannot see this profile)');
  console.log('');
  console.log('If the same query with SERVICE ROLE returns a row, RLS is the cause of "not registered".');
}
