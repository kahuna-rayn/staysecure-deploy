-- =============================================================================
-- Profile: last_sign_in_at helper function
-- =============================================================================
-- Allows authenticated admins to read last_sign_in_at from auth.users
-- for any user ID, without exposing other auth fields.
--
-- Apply to all client Supabase instances.
-- Safe to re-run: uses CREATE OR REPLACE.
-- Run as: postgres / service role in the Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_user_last_sign_in(target_user_id uuid)
RETURNS timestamptz
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT last_sign_in_at
  FROM auth.users
  WHERE id = target_user_id;
$$;

-- Restrict to authenticated users only (admins calling from the app)
REVOKE ALL ON FUNCTION public.get_user_last_sign_in(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_last_sign_in(uuid) TO authenticated;
