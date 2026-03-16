-- Post-Migration Fixes (Minimal)
-- This file contains fixes NOT captured by pg_dump of public schema
--
-- Apply this file after running onboard-client.sh or schema restoration

SET search_path = public;

-- ========================================
-- REQUIRED: Auth Users Trigger
-- ========================================
-- pg_dump of public schema doesn't capture triggers on auth.users
-- This trigger fires handle_new_user() when new users are created

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created 
AFTER INSERT ON auth.users 
FOR EACH ROW 
EXECUTE FUNCTION public.handle_new_user();

-- ========================================
-- REQUIRED: Function Permissions
-- ========================================
-- Ensure handle_new_user can insert profiles via trigger

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;
GRANT INSERT ON public.profiles TO postgres;
-- ========================================
-- REQUIRED: Storage Bucket Policies
-- ========================================
-- pg_dump of public schema doesn't capture storage.objects policies
-- These allow lesson media uploads in the avatars bucket

-- Upload lesson media (super_admins and authors)
DROP POLICY IF EXISTS "Super admins and authors can upload lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can upload lesson media"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'avatars' AND
  (name)::text LIKE 'lesson-media/%' AND
  (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

-- Read lesson media (super_admins and authors - for editing)
DROP POLICY IF EXISTS "Super admins and authors can read lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can read lesson media"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'avatars' AND
  (name)::text LIKE 'lesson-media/%' AND
  (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

-- Read lesson media (all authenticated users - for viewing lessons)
DROP POLICY IF EXISTS "Authenticated users can read lesson media" ON storage.objects;
CREATE POLICY "Authenticated users can read lesson media"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'avatars' AND
  (name)::text LIKE 'lesson-media/%'
);

-- Delete lesson media (super_admins and authors)
DROP POLICY IF EXISTS "Super admins and authors can delete lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can delete lesson media"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'avatars' AND
  (name)::text LIKE 'lesson-media/%' AND
  (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

-- Update lesson media (super_admins and authors)
DROP POLICY IF EXISTS "Super admins and authors can update lesson media" ON storage.objects;
CREATE POLICY "Super admins and authors can update lesson media"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'avatars' AND
  (name)::text LIKE 'lesson-media/%' AND
  (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
)
WITH CHECK (
  bucket_id = 'avatars' AND
  (name)::text LIKE 'lesson-media/%' AND
  (public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))
);

-- ========================================
-- REQUIRED: Knowledge Documents Bucket
-- ========================================
-- The 'documents' bucket must be created via the Management API (not SQL INSERT)
-- because Supabase internal storage metadata is not initialised by direct inserts.
-- onboard-client.sh creates the bucket via the API before running this file.
-- The policy below is safe to run even if the bucket doesn't exist yet — it will
-- apply once the bucket is created.

DROP POLICY IF EXISTS "Admins can manage document files" ON storage.objects;
CREATE POLICY "Admins can manage document files"
ON storage.objects
FOR ALL
TO authenticated
USING (
  bucket_id = 'documents'
  AND EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid()
      AND role IN ('super_admin', 'client_admin')
  )
)
WITH CHECK (
  bucket_id = 'documents'
  AND EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid()
      AND role IN ('super_admin', 'client_admin')
  )
);

