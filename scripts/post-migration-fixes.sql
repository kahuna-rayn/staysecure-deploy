-- Post-Migration Fixes
-- Applied after schema restore during onboard-client.sh
--
-- Only contains things pg_dump --schema=public CANNOT capture:
--   1. Triggers on auth.users  (auth schema is not dumped)
--   2. storage.objects policies (storage schema is not in public dump)
--
-- Everything else (RLS policies, functions, tables, columns) comes from
-- the master schema dump and does not need to be repeated here.

SET search_path = public;

-- ========================================
-- 1. Auth Users Trigger
-- ========================================
-- Fires handle_new_user() when Supabase creates a new auth user.
-- Lives on auth.users which is outside the public schema dump.

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_user();

-- ========================================
-- 2. Storage Bucket Policies
-- ========================================
-- storage.objects policies are not captured by pg_dump --schema=public.

-- ── avatars bucket: lesson-media folder ─────────────────────────────────────

DROP POLICY IF EXISTS "Super admins and authors can upload lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can upload lesson media"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'avatars'
  AND (name)::text LIKE 'lesson-media/%'
  AND (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

DROP POLICY IF EXISTS "Super admins and authors can read lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can read lesson media"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'avatars'
  AND (name)::text LIKE 'lesson-media/%'
  AND (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

DROP POLICY IF EXISTS "Authenticated users can read lesson media" ON storage.objects;
CREATE POLICY "Authenticated users can read lesson media"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'avatars'
  AND (name)::text LIKE 'lesson-media/%'
);

DROP POLICY IF EXISTS "Super admins and authors can delete lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can delete lesson media"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'avatars'
  AND (name)::text LIKE 'lesson-media/%'
  AND (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

DROP POLICY IF EXISTS "Super admins and authors can update lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can update lesson media"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'avatars'
  AND (name)::text LIKE 'lesson-media/%'
  AND (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
)
WITH CHECK (
  bucket_id = 'avatars'
  AND (name)::text LIKE 'lesson-media/%'
  AND (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

-- ── documents bucket ─────────────────────────────────────────────────────────
-- Uses can_manage_documents() (SECURITY DEFINER, defined in migration
-- 20260427000000_can_manage_documents.sql) to allow super_admin, client_admin,
-- and managers to upload/delete. The old inline user_roles policy is dropped to
-- prevent a duplicate that caused TCP timeouts in the storage RLS context.

DROP POLICY IF EXISTS "Admins can manage document files"               ON storage.objects;
DROP POLICY IF EXISTS "Managers can manage document files"             ON storage.objects;
DROP POLICY IF EXISTS "Admins and managers can manage document files"  ON storage.objects;

CREATE POLICY "Admins and managers can manage document files"
ON storage.objects FOR ALL TO authenticated
USING  (bucket_id = 'documents' AND public.can_manage_documents())
WITH CHECK (bucket_id = 'documents' AND public.can_manage_documents());

-- ── certificates bucket ───────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Users can read own certificate files" ON storage.objects;
CREATE POLICY "Users can read own certificate files"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'certificates'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Admins can manage certificate files" ON storage.objects;
CREATE POLICY "Admins can manage certificate files"
ON storage.objects FOR ALL TO authenticated
USING (
  bucket_id = 'certificates'
  AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
)
WITH CHECK (
  bucket_id = 'certificates'
  AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
);

-- ── logos bucket ──────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Public read for org logos" ON storage.objects;
CREATE POLICY "Public read for org logos"
ON storage.objects FOR SELECT TO public
USING (bucket_id = 'logos');

DROP POLICY IF EXISTS "Admins can manage org logos" ON storage.objects;
CREATE POLICY "Admins can manage org logos"
ON storage.objects FOR ALL TO authenticated
USING (
  bucket_id = 'logos'
  AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
)
WITH CHECK (
  bucket_id = 'logos'
  AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('super_admin', 'client_admin'))
);
