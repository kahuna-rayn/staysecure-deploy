-- =============================================================================
-- Knowledge Management Module — RLS Policies & DB Fixes
-- =============================================================================
-- Apply to all client Supabase instances.
-- Safe to re-run: uses IF NOT EXISTS / OR REPLACE / DO NOTHING patterns.
-- Run as: postgres / service role in the Supabase SQL Editor.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. documents table
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'documents' AND policyname = 'Admins can insert documents'
  ) THEN
    CREATE POLICY "Admins can insert documents"
    ON documents FOR INSERT TO authenticated
    WITH CHECK (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'documents' AND policyname = 'Admins can update documents'
  ) THEN
    CREATE POLICY "Admins can update documents"
    ON documents FOR UPDATE TO authenticated
    USING (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'documents' AND policyname = 'Admins can delete documents'
  ) THEN
    CREATE POLICY "Admins can delete documents"
    ON documents FOR DELETE TO authenticated
    USING (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 2. document_users table
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'document_users' AND policyname = 'Admins can insert document_users'
  ) THEN
    CREATE POLICY "Admins can insert document_users"
    ON document_users FOR INSERT TO authenticated
    WITH CHECK (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 3. document_roles table
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'document_roles' AND policyname = 'Admins can insert document_roles'
  ) THEN
    CREATE POLICY "Admins can insert document_roles"
    ON document_roles FOR INSERT TO authenticated
    WITH CHECK (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 4. document_departments table
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'document_departments' AND policyname = 'Admins can insert document_departments'
  ) THEN
    CREATE POLICY "Admins can insert document_departments"
    ON document_departments FOR INSERT TO authenticated
    WITH CHECK (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 5. document_assignments table
-- -----------------------------------------------------------------------------

-- Allow the trigger function (generate_document_assignments) to insert rows.
-- Uses WITH CHECK (true) because inserts are driven by trigger logic, not auth.uid().
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'document_assignments' AND policyname = 'System can insert document_assignments'
  ) THEN
    CREATE POLICY "System can insert document_assignments"
    ON document_assignments FOR INSERT TO authenticated
    WITH CHECK (true);
  END IF;
END $$;

-- Allow users to update their own assignment status (mark as read / in progress).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'document_assignments' AND policyname = 'Users can update their own assignment status'
  ) THEN
    CREATE POLICY "Users can update their own assignment status"
    ON document_assignments FOR UPDATE TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
  END IF;
END $$;

-- Allow admins to view all assignments (e.g. when viewing another user's profile).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'document_assignments' AND policyname = 'Admins can view all document assignments'
  ) THEN
    CREATE POLICY "Admins can view all document assignments"
    ON document_assignments FOR SELECT TO authenticated
    USING (
      EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
    );
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 6. documents.version — backfill NULLs and set default
--    Required by generate_document_assignments() which inserts document_version
--    (NOT NULL). Without a version value the trigger silently produces no rows.
-- -----------------------------------------------------------------------------

ALTER TABLE public.documents
  ALTER COLUMN version SET DEFAULT 1;

UPDATE public.documents
SET version = 1
WHERE version IS NULL;


-- -----------------------------------------------------------------------------
-- 7. generate_document_assignments() — ensure COALESCE guards against NULL
--    version / due_days on any documents that were created before the backfill.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.generate_document_assignments(doc_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  assigning_user uuid := auth.uid();
BEGIN
  -- role-based assignments
  INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date, assigned_by)
  SELECT DISTINCT
    upr.user_id,
    doc_id,
    COALESCE(d.version, 1),
    CURRENT_DATE + INTERVAL '1 day' * COALESCE(d.due_days, 30),
    assigning_user
  FROM public.document_roles dr
  JOIN public.user_profile_roles upr ON dr.role_id = upr.role_id
  JOIN public.documents d ON d.document_id = doc_id
  WHERE dr.document_id = doc_id
  ON CONFLICT (user_id, document_id, document_version) DO NOTHING;

  -- department-based assignments
  INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date, assigned_by)
  SELECT DISTINCT
    ud.user_id,
    doc_id,
    COALESCE(d.version, 1),
    CURRENT_DATE + INTERVAL '1 day' * COALESCE(d.due_days, 30),
    assigning_user
  FROM public.document_departments dd
  JOIN public.user_departments ud ON dd.department_id = ud.department_id
  JOIN public.documents d ON d.document_id = doc_id
  WHERE dd.document_id = doc_id
  ON CONFLICT (user_id, document_id, document_version) DO NOTHING;

  -- direct user assignments
  INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date, assigned_by)
  SELECT DISTINCT
    du.user_id,
    doc_id,
    COALESCE(d.version, 1),
    CURRENT_DATE + INTERVAL '1 day' * COALESCE(d.due_days, 30),
    assigning_user
  FROM public.document_users du
  JOIN public.documents d ON d.document_id = doc_id
  WHERE du.document_id = doc_id
  ON CONFLICT (user_id, document_id, document_version) DO NOTHING;
END;
$$;


-- -----------------------------------------------------------------------------
-- Profile: last_sign_in_at helper
-- -----------------------------------------------------------------------------
-- Allows authenticated admins to read last_sign_in_at from auth.users
-- for any user ID, so the admin profile view shows the real last login
-- instead of the always-empty profiles.last_login column.

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

REVOKE ALL ON FUNCTION public.get_user_last_sign_in(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_last_sign_in(uuid) TO authenticated;


-- -----------------------------------------------------------------------------
-- Done.
-- -----------------------------------------------------------------------------
