--
-- PostgreSQL database dump
--

\restrict SxTa4dJQhePpmpSjMETdT87JZlB1otDZxCFH61b1cyFIgNJgs2SueOrxECQEDEV

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: access_level_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.access_level_type AS ENUM (
    'admin',
    'manager',
    'user',
    'super_admin'
);


--
-- Name: TYPE access_level_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.access_level_type IS 'Access level for license management';


--
-- Name: activity_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.activity_type AS ENUM (
    'Risk assessment',
    'Incident response',
    'Business continuity',
    'Data protection',
    'Access control',
    'Security monitoring',
    'Compliance audit',
    'Training and awareness'
);


--
-- Name: app_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.app_role AS ENUM (
    'admin',
    'user',
    'super_admin',
    'client_admin',
    'manager',
    'author',
    'auditor'
);


--
-- Name: approval_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.approval_status_enum AS ENUM (
    'Not Submitted',
    'Submitted',
    'Rejected',
    'Approved'
);


--
-- Name: add_breach_team_assignments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_breach_team_assignments() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  -- Add to user_departments if department_id is provided
  IF NEW.department_id IS NOT NULL THEN
    INSERT INTO public.user_departments (user_id, department_id, is_primary, assigned_by, pairing_id)
    VALUES (NEW.user_id, NEW.department_id, NEW.is_primary, NEW.assigned_by, NEW.breach_team_id)
    ON CONFLICT (user_id, department_id) DO UPDATE SET
      is_primary = NEW.is_primary,
      assigned_by = NEW.assigned_by,
      pairing_id = NEW.breach_team_id,
      updated_at = now();
  END IF;

  -- Add to user_profile_roles if role_id is provided
  IF NEW.role_id IS NOT NULL THEN
    INSERT INTO public.user_profile_roles (user_id, role_id, is_primary, assigned_by, pairing_id)
    VALUES (NEW.user_id, NEW.role_id, NEW.is_primary, NEW.assigned_by, NEW.breach_team_id)
    ON CONFLICT (user_id, role_id) DO UPDATE SET
      is_primary = NEW.is_primary,
      assigned_by = NEW.assigned_by,
      pairing_id = NEW.breach_team_id,
      updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: assess_change_magnitude(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assess_change_magnitude(old_value text, new_value text) RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF LENGTH(COALESCE(new_value, '')) - LENGTH(COALESCE(old_value, '')) > 100 THEN
    RETURN 'major';
  ELSIF LENGTH(COALESCE(new_value, '')) - LENGTH(COALESCE(old_value, '')) > 20 THEN
    RETURN 'moderate';
  ELSE
    RETURN 'minor';
  END IF;
END;
$$;


--
-- Name: check_outdated_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_outdated_status() RETURNS TABLE(table_name text, total_completed bigint, outdated_completed bigint, needs_fixing boolean)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    'lesson_translations' as table_name,
    COUNT(*) as total_completed,
    COUNT(CASE WHEN is_outdated THEN 1 END) as outdated_completed,
    COUNT(CASE WHEN is_outdated AND status = 'completed' THEN 1 END) > 0 as needs_fixing
  FROM public.lesson_translations 
  WHERE status = 'completed'
  
  UNION ALL
  
  SELECT 
    'lesson_node_translations' as table_name,
    COUNT(*) as total_completed,
    COUNT(CASE WHEN is_outdated THEN 1 END) as outdated_completed,
    COUNT(CASE WHEN is_outdated AND status = 'completed' THEN 1 END) > 0 as needs_fixing
  FROM public.lesson_node_translations 
  WHERE status = 'completed';
END;
$$;


--
-- Name: cleanup_breach_team_assignments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_breach_team_assignments() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  -- Delete from user_departments if department_id was assigned
  IF OLD.department_id IS NOT NULL THEN
    DELETE FROM public.user_departments 
    WHERE user_id = OLD.user_id 
      AND department_id = OLD.department_id 
      AND pairing_id = OLD.breach_team_id;
  END IF;

  -- Delete from user_profile_roles if role_id was assigned
  IF OLD.role_id IS NOT NULL THEN
    DELETE FROM public.user_profile_roles 
    WHERE user_id = OLD.user_id 
      AND role_id = OLD.role_id 
      AND pairing_id = OLD.breach_team_id;
  END IF;

  RETURN OLD;
END;
$$;


--
-- Name: debug_outdated_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.debug_outdated_status() RETURNS TABLE(lesson_id uuid, lesson_title text, language_code text, is_outdated boolean, last_modified timestamp with time zone, translation_updated timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    l.id as lesson_id,
    l.title as lesson_title,
    lt.language_code::text,
    lt.is_outdated,
    l.updated_at as last_modified,
    lt.updated_at as translation_updated
  FROM lessons l
  JOIN lesson_translations lt ON l.id = lt.lesson_id
  WHERE lt.is_outdated = TRUE
  ORDER BY l.updated_at DESC;
END;
$$;


--
-- Name: debug_translation_data(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.debug_translation_data() RETURNS TABLE(lesson_id text, lesson_title text, language_code text, created_at timestamp with time zone, status text, translation_cost numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    lt.lesson_id::text,
    l.title,
    lt.language_code::text,
    lt.created_at,
    lt.status::text,  -- Cast status to text
    lt.translation_cost
  FROM lesson_translations lt
  LEFT JOIN lessons l ON lt.lesson_id = l.id
  ORDER BY lt.created_at DESC;
END;
$$;


--
-- Name: fix_existing_outdated_flags(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fix_existing_outdated_flags() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Reset is_outdated to FALSE for all completed lesson translations
  UPDATE public.lesson_translations 
  SET is_outdated = FALSE 
  WHERE status = 'completed' AND is_outdated = TRUE;
  
  -- Reset is_outdated to FALSE for all completed node translations
  UPDATE public.lesson_node_translations 
  SET is_outdated = FALSE 
  WHERE status = 'completed' AND is_outdated = TRUE;
  
  RAISE NOTICE 'Fixed outdated flags for completed translations';
END;
$$;


--
-- Name: generate_assignments_for_user_department(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_assignments_for_user_department() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Generate assignments for all documents assigned to this department
    INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date)
    SELECT DISTINCT 
        NEW.user_id,
        dd.document_id,
        d.version,
        CURRENT_DATE + INTERVAL '1 day' * d.due_days
    FROM public.document_departments dd
    JOIN public.documents d ON d.document_id = dd.document_id
    WHERE dd.department_id = NEW.department_id
    ON CONFLICT (user_id, document_id, document_version) DO NOTHING;
    
    RETURN NEW;
END;
$$;


--
-- Name: generate_assignments_for_user_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_assignments_for_user_role() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Generate assignments for all documents assigned to this role
    INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date)
    SELECT DISTINCT 
        NEW.user_id,
        dr.document_id,
        d.version,
        CURRENT_DATE + INTERVAL '1 day' * d.due_days
    FROM public.document_roles dr
    JOIN public.documents d ON d.document_id = dr.document_id
    WHERE dr.role_id = NEW.role_id
    ON CONFLICT (user_id, document_id, document_version) DO NOTHING;
    
    RETURN NEW;
END;
$$;


--
-- Name: generate_content_hash(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_content_hash(content text, media_alt text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN encode(digest(COALESCE(content, '') || COALESCE(media_alt, ''), 'sha256'), 'hex');
END;
$$;


--
-- Name: generate_document_assignments(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_document_assignments(doc_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Generate assignments for role-based targets
    INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date)
    SELECT DISTINCT 
        upr.user_id,
        doc_id,
        d.version,
        CURRENT_DATE + INTERVAL '1 day' * d.due_days
    FROM public.document_roles dr
    JOIN public.user_profile_roles upr ON dr.role_id = upr.role_id
    JOIN public.documents d ON d.document_id = doc_id
    WHERE dr.document_id = doc_id
    ON CONFLICT (user_id, document_id, document_version) DO NOTHING;
    
    -- Generate assignments for department-based targets
    INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date)
    SELECT DISTINCT 
        ud.user_id,
        doc_id,
        d.version,
        CURRENT_DATE + INTERVAL '1 day' * d.due_days
    FROM public.document_departments dd
    JOIN public.user_departments ud ON dd.department_id = ud.department_id
    JOIN public.documents d ON d.document_id = doc_id
    WHERE dd.document_id = doc_id
    ON CONFLICT (user_id, document_id, document_version) DO NOTHING;
    
    -- Generate assignments for direct user targets
    INSERT INTO public.document_assignments (user_id, document_id, document_version, due_date)
    SELECT DISTINCT 
        du.user_id,
        doc_id,
        d.version,
        CURRENT_DATE + INTERVAL '1 day' * d.due_days
    FROM public.document_users du
    JOIN public.documents d ON d.document_id = doc_id
    WHERE du.document_id = doc_id
    ON CONFLICT (user_id, document_id, document_version) DO NOTHING;
END;
$$;


--
-- Name: generate_learning_track_assignments(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_learning_track_assignments(track_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  track_record RECORD;
  user_record RECORD;
BEGIN
  -- Get track details
  SELECT * INTO track_record FROM learning_tracks WHERE id = track_id;
  
  -- Create individual assignments for department-based assignments
  FOR user_record IN 
    SELECT DISTINCT u.id as user_id
    FROM learning_track_department_assignments ltda
    INNER JOIN user_departments ud ON ud.department_id = ltda.department_id
    INNER JOIN auth.users u ON u.id = ud.user_id
    WHERE ltda.learning_track_id = track_id
    AND NOT EXISTS (
      SELECT 1 FROM learning_track_assignments lta 
      WHERE lta.learning_track_id = track_id 
      AND lta.user_id = u.id
    )
  LOOP
    INSERT INTO learning_track_assignments (
      learning_track_id,
      user_id,
      assigned_by,
      status,
      completion_required
    ) VALUES (
      track_id,
      user_record.user_id,
      (SELECT assigned_by FROM learning_track_department_assignments 
       WHERE learning_track_id = track_id LIMIT 1),
      'assigned',
      true
    );
  END LOOP;

  -- Create individual assignments for role-based assignments
  FOR user_record IN 
    SELECT DISTINCT u.id as user_id
    FROM learning_track_role_assignments ltra
    INNER JOIN user_profile_roles upr ON upr.role_id = ltra.role_id
    INNER JOIN auth.users u ON u.id = upr.user_id
    WHERE ltra.learning_track_id = track_id
    AND NOT EXISTS (
      SELECT 1 FROM learning_track_assignments lta 
      WHERE lta.learning_track_id = track_id 
      AND lta.user_id = u.id
    )
  LOOP
    INSERT INTO learning_track_assignments (
      learning_track_id,
      user_id,
      assigned_by,
      status,
      completion_required
    ) VALUES (
      track_id,
      user_record.user_id,
      (SELECT assigned_by FROM learning_track_role_assignments 
       WHERE learning_track_id = track_id LIMIT 1),
      'assigned',
      true
    );
  END LOOP;
END;
$$;


--
-- Name: get_active_rules_for_event(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_active_rules_for_event(p_event_type text) RETURNS TABLE(rule_id uuid, rule_name text, email_template_id uuid, template_type text, subject_template text, html_body_template text, template_variables jsonb, trigger_conditions jsonb, send_immediately boolean, send_at_time time without time zone, default_priority text)
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT 
    nr.id as rule_id,
    nr.name as rule_name,
    et.id as email_template_id,
    et.type as template_type,
    et.subject_template,
    et.html_body_template,
    et.variables as template_variables,
    nr.trigger_conditions,
    nr.send_immediately,
    nr.send_at_time,
    COALESCE(nr.override_priority, et.default_priority, 'normal') as default_priority
  FROM public.notification_rules nr
  INNER JOIN public.email_templates et ON nr.email_template_id = et.id
  WHERE nr.is_enabled = true
    AND COALESCE(et.is_active, true) = true
    AND nr.trigger_event = p_event_type
  ORDER BY nr.created_at;
$$;


--
-- Name: get_active_translation_jobs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_active_translation_jobs() RETURNS TABLE(id uuid, lesson_title text, target_language text, status text, total_items integer, completed_items integer, failed_items integer, total_cost numeric, created_at timestamp with time zone, updated_at timestamp with time zone, progress_percentage numeric, estimated_seconds_remaining integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    tj.id,
    l.title as lesson_title,
    tj.target_language::text as target_language,
    tj.status::text as status,
    tj.total_items,
    tj.completed_items,
    tj.failed_items,
    tj.total_cost,
    tj.created_at,
    tj.updated_at,
    
    -- Calculate progress percentage
    CASE 
      WHEN tj.total_items > 0 THEN 
        ROUND((tj.completed_items::DECIMAL / tj.total_items) * 100, 1)
      ELSE 0 
    END as progress_percentage,
    
    -- Estimate completion time
    CASE 
      WHEN tj.status = 'processing' AND tj.completed_items > 0 THEN
        EXTRACT(EPOCH FROM (
          (NOW() - tj.created_at) * 
          (tj.total_items - tj.completed_items) / 
          tj.completed_items
        ))::INTEGER
      ELSE NULL
    END as estimated_seconds_remaining

  FROM translation_jobs tj
  JOIN lessons l ON tj.lesson_id = l.id
  WHERE tj.status IN ('pending', 'processing')
  ORDER BY tj.priority DESC, tj.created_at ASC;
END;
$$;


--
-- Name: get_current_user_managed_departments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_user_managed_departments() RETURNS TABLE(department_id uuid)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT d.id
  FROM departments d
  WHERE d.manager_id = auth.uid();
END;
$$;


--
-- Name: get_current_user_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_user_role() RETURNS public.app_role
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT role FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1;
$$;


--
-- Name: get_key_dates(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_key_dates() RETURNS TABLE(id uuid, key_activity text, due_date timestamp with time zone, updated_due_date timestamp with time zone, frequency text, certificate text, created_at timestamp with time zone, modified_at timestamp with time zone, created_by uuid, modified_by uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    kd.id,
    kd.key_activity,
    kd.due_date,
    kd.updated_due_date,
    kd.frequency,
    kd.certificate,
    kd.created_at,
    kd.modified_at,
    kd.created_by,
    kd.modified_by
  FROM public.key_dates kd
  ORDER BY kd.due_date ASC NULLS LAST;
END;
$$;


--
-- Name: get_lessons_with_outdated_content(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_lessons_with_outdated_content() RETURNS TABLE(lesson_id uuid, lesson_title text, last_modified timestamp with time zone, created_by uuid, outdated_languages jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  -- Check if user has admin or super_admin role
  IF NOT EXISTS (
    SELECT 1 FROM user_roles 
    WHERE user_id = auth.uid() 
    AND role IN ('admin'::app_role, 'super_admin'::app_role)
  ) THEN
    -- Return empty result for unauthorized users
    RETURN;
  END IF;

  RETURN QUERY
  SELECT 
    l.id as lesson_id,
    l.title as lesson_title,
    l.updated_at as last_modified,
    l.created_by,
    jsonb_agg(
      jsonb_build_object(
        'language_code', lt.language_code,
        'last_translated', lt.updated_at,
        'is_outdated', lt.is_outdated
      )
    ) as outdated_languages
  FROM lessons l
  INNER JOIN lesson_translations lt ON l.id = lt.lesson_id
  WHERE lt.is_outdated = TRUE
  GROUP BY l.id, l.title, l.updated_at, l.created_by
  ORDER BY l.updated_at DESC;
END;
$$;


--
-- Name: get_lessons_with_outdated_content_public(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_lessons_with_outdated_content_public() RETURNS TABLE(lesson_id uuid, lesson_title text, last_modified timestamp with time zone, created_by uuid, outdated_languages jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  -- Temporary function without auth check for testing
  RETURN QUERY
  SELECT 
    l.id as lesson_id,
    l.title as lesson_title,
    l.updated_at as last_modified,
    l.created_by,
    jsonb_agg(
      jsonb_build_object(
        'language_code', lt.language_code,
        'last_translated', lt.updated_at,
        'is_outdated', lt.is_outdated
      )
    ) as outdated_languages
  FROM lessons l
  INNER JOIN lesson_translations lt ON l.id = lt.lesson_id
  WHERE lt.is_outdated = TRUE
  GROUP BY l.id, l.title, l.updated_at, l.created_by
  ORDER BY l.updated_at DESC;
END;
$$;


--
-- Name: get_monthly_translation_spend(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_monthly_translation_spend() RETURNS TABLE(total_monthly_spend numeric, spend_by_language jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  WITH monthly_spend AS (
    SELECT 
      COALESCE(SUM(translation_cost), 0) as total_spend
    FROM lesson_translations 
    WHERE created_at >= DATE_TRUNC('month', CURRENT_DATE)
  ),
  language_spend AS (
    SELECT 
      language_code,
      COALESCE(SUM(translation_cost), 0) as spend,
      COUNT(*) as translation_count
    FROM lesson_translations 
    WHERE created_at >= DATE_TRUNC('month', CURRENT_DATE)
      AND language_code IS NOT NULL
    GROUP BY language_code
    ORDER BY spend DESC
  )
  SELECT 
    ms.total_spend,
    jsonb_agg(
      jsonb_build_object(
        'language', ls.language_code,
        'spend', ls.spend,
        'count', ls.translation_count
      )
    ) as spend_by_language
  FROM monthly_spend ms
  CROSS JOIN language_spend ls
  GROUP BY ms.total_spend;
END;
$$;


--
-- Name: get_nodes_needing_translation(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_nodes_needing_translation(lesson_id uuid, language_code text) RETURNS TABLE(node_id text, content text, media_alt text, content_hash text, last_translation_hash text, needs_translation boolean)
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Check if user has admin role
  IF NOT EXISTS (
    SELECT 1 FROM user_roles 
    WHERE user_id = auth.uid() AND role = 'admin'::app_role
  ) THEN
    -- Return empty result for non-admin users
    RETURN;
  END IF;

  RETURN QUERY
  SELECT 
    ln.id as node_id,
    ln.content,
    ln.media_alt,
    ln.content_hash,
    lnt.content_hash as last_translation_hash,
    (ln.content_hash != lnt.content_hash OR lnt.content_hash IS NULL) as needs_translation
  FROM lesson_nodes ln
  LEFT JOIN lesson_node_translations lnt ON ln.id = lnt.node_id AND lnt.language_code = language_code
  WHERE ln.lesson_id = lesson_id;
END;
$$;


--
-- Name: get_outdated_lessons(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_outdated_lessons() RETURNS TABLE(id uuid, title text, last_modified timestamp with time zone, created_by uuid, translation_count bigint, outdated_count bigint, node_count bigint, outdated_node_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Check if user has admin role
  IF NOT EXISTS (
    SELECT 1 FROM user_roles 
    WHERE user_id = auth.uid() AND role = 'admin'::app_role
  ) THEN
    -- Return empty result for non-admin users
    RETURN;
  END IF;

  RETURN QUERY
  WITH lesson_translation_status AS (
    SELECT 
      l.id,
      l.title,
      l.updated_at as last_modified,
      l.created_by,
      COUNT(DISTINCT lt.language_code) as translation_count,
      COUNT(DISTINCT CASE WHEN lt.is_outdated = true THEN lt.language_code END) as outdated_count,
      COUNT(DISTINCT ln.id) as node_count,
      COUNT(DISTINCT CASE WHEN lnt.is_outdated = true THEN lnt.node_id END) as outdated_node_count
    FROM lessons l
    LEFT JOIN lesson_translations lt ON l.id = lt.lesson_id
    LEFT JOIN lesson_nodes ln ON l.id = ln.lesson_id
    LEFT JOIN lesson_node_translations lnt ON ln.id = lnt.node_id
    GROUP BY l.id, l.title, l.updated_at, l.created_by
  )
  SELECT 
    lts.id,
    lts.title,
    lts.last_modified,
    lts.created_by,
    lts.translation_count,
    lts.outdated_count,
    lts.node_count,
    lts.outdated_node_count
  FROM lesson_translation_status lts
  WHERE lts.outdated_count > 0 OR lts.outdated_node_count > 0
  ORDER BY lts.last_modified DESC;
END;
$$;


--
-- Name: get_outdated_lessons_grouped(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_outdated_lessons_grouped() RETURNS TABLE(lesson_id uuid, lesson_title text, last_modified timestamp with time zone, created_by uuid, outdated_languages jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    l.id as lesson_id,
    l.title as lesson_title,
    l.updated_at as last_modified,
    l.created_by,
    jsonb_agg(
      jsonb_build_object(
        'language_code', lt.language_code,
        'last_translated', lt.updated_at,
        'is_outdated', lt.is_outdated
      )
    ) as outdated_languages
  FROM lessons l
  JOIN lesson_translations lt ON l.id = lt.lesson_id
  WHERE lt.is_outdated = TRUE
  GROUP BY l.id, l.title, l.updated_at, l.created_by
  ORDER BY l.updated_at DESC;
END;
$$;


--
-- Name: get_recent_translation_activity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_recent_translation_activity() RETURNS TABLE(activity_type text, lesson_title text, language_code text, activity_time timestamp with time zone, cost numeric, user_email text)
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Check if user has admin role
  IF NOT EXISTS (
    SELECT 1 FROM user_roles 
    WHERE user_id = auth.uid() AND role = 'admin'::app_role
  ) THEN
    -- Return empty result for non-admin users
    RETURN;
  END IF;

  RETURN QUERY
  WITH recent_activity AS (
    -- Translation completions
    SELECT 
      'translation_completed'::text as activity_type,
      l.title::text as lesson_title,
      lt.language_code::text as language_code,
      lt.created_at as activity_time,
      lt.translation_cost as cost,
      NULL::text as user_email
    FROM lesson_translations lt
    JOIN lessons l ON lt.lesson_id = l.id
    WHERE lt.status = 'completed'
    
    UNION ALL
    
    -- Content modifications (only if user has access to translation_change_log)
    SELECT 
      'content_modified'::text as activity_type,
      l.title::text as lesson_title,
      NULL::text as language_code,
      tcl.updated_at as activity_time,
      NULL::numeric as cost,
      NULL::text as user_email -- Don't expose user emails for security
    FROM translation_change_log tcl
    JOIN lessons l ON tcl.lesson_id = l.id
    WHERE tcl.updated_at > CURRENT_DATE - INTERVAL '7 days'
      AND tcl.change_type = 'updated'
    
    UNION ALL
    
    -- Translation jobs started (only if user has access to translation_jobs)
    SELECT 
      'translation_started'::text as activity_type,
      l.title::text as lesson_title,
      tj.target_language::text as language_code,
      tj.created_at as activity_time,
      tj.total_cost as cost,
      NULL::text as user_email -- Don't expose user emails for security
    FROM translation_jobs tj
    JOIN lessons l ON tj.lesson_id = l.id
    WHERE tj.created_at > CURRENT_DATE - INTERVAL '7 days'
  )
  SELECT *
  FROM recent_activity
  ORDER BY activity_time DESC
  LIMIT 20;
END;
$$;


--
-- Name: get_translation_dashboard_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_translation_dashboard_stats() RETURNS TABLE(total_lessons bigint, translated_lessons bigint, lessons_needing_updates bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  WITH lesson_translation_status AS (
    SELECT 
      l.id,
      l.title,
      l.updated_at as last_modified,
      l.created_by,
      COUNT(DISTINCT lt.language_code) as translation_count,
      COUNT(DISTINCT CASE WHEN lt.is_outdated = true THEN lt.language_code END) as outdated_count,
      COUNT(DISTINCT ln.id) as node_count,
      COUNT(DISTINCT CASE WHEN lnt.is_outdated = true THEN lnt.node_id END) as outdated_node_count
    FROM lessons l
    LEFT JOIN lesson_translations lt ON l.id = lt.lesson_id
    LEFT JOIN lesson_nodes ln ON l.id = ln.lesson_id
    LEFT JOIN lesson_node_translations lnt ON ln.id = lnt.node_id
    GROUP BY l.id, l.title, l.updated_at, l.created_by
  )
  SELECT 
    COUNT(*) as total_lessons,
    COUNT(CASE WHEN translation_count > 0 THEN 1 END) as translated_lessons,
    COUNT(CASE WHEN outdated_count > 0 OR outdated_node_count > 0 THEN 1 END) as lessons_needing_updates
  FROM lesson_translation_status;
END;
$$;


--
-- Name: get_user_assigned_tracks(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_assigned_tracks(user_id uuid) RETURNS TABLE(track_id uuid, assignment_id uuid, status text, completion_required boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  -- Direct individual assignments
  SELECT 
    lta.learning_track_id,
    lta.assignment_id,
    lta.status,
    lta.completion_required
  FROM learning_track_assignments lta
  WHERE lta.user_id = get_user_assigned_tracks.user_id
  
  UNION
  
  -- Department-based assignments
  SELECT 
    ltda.learning_track_id,
    ltda.assignment_id,
    'assigned'::TEXT as status,
    true as completion_required
  FROM learning_track_department_assignments ltda
  INNER JOIN user_departments ud ON ud.department_id = ltda.department_id
  WHERE ud.user_id = get_user_assigned_tracks.user_id
  
  UNION
  
  -- Role-based assignments
  SELECT 
    ltra.learning_track_id,
    ltra.assignment_id,
    'assigned'::TEXT as status,
    true as completion_required
  FROM learning_track_role_assignments ltra
  INNER JOIN user_profile_roles upr ON upr.role_id = ltra.role_id
  WHERE upr.user_id = get_user_assigned_tracks.user_id;
END;
$$;


--
-- Name: FUNCTION get_user_assigned_tracks(user_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_user_assigned_tracks(user_id uuid) IS 'Get all learning tracks assigned to a specific user (updated to match actual table structure)';


--
-- Name: get_user_email_by_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_email_by_id(user_id uuid) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT email FROM auth.users WHERE id = user_id;
$$;


--
-- Name: get_user_id_by_email(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_id_by_email(email text) RETURNS TABLE(id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
BEGIN
  RETURN QUERY SELECT au.id FROM auth.users au WHERE au.email = $1;
END;
$_$;


--
-- Name: get_users_needing_lesson_reminders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_users_needing_lesson_reminders() RETURNS TABLE(user_id uuid, user_email text, lesson_id uuid, lesson_title text, lesson_description text, learning_track_id uuid, learning_track_title text, available_date date, order_index integer, reminder_type text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  WITH user_tracks AS (
    -- Get all users enrolled in learning tracks with their progress
    -- Only include users who have email enabled globally
    SELECT 
      ultp.user_id,
      ultp.learning_track_id,
      ultp.enrolled_at,
      ultp.current_lesson_order,
      lt.title::TEXT as track_title,
      lt.schedule_type,
      lt.start_date,
      lt.end_date,
      lt.duration_weeks,
      lt.lessons_per_week,
      lt.allow_all_lessons_immediately,
      lt.schedule_days,
      lt.max_lessons_per_week,
      au.email::TEXT as user_email
    FROM public.user_learning_track_progress ultp
    INNER JOIN public.learning_tracks lt ON ultp.learning_track_id = lt.id
    INNER JOIN auth.users au ON ultp.user_id = au.id
    LEFT JOIN public.email_preferences ep ON ep.user_id = ultp.user_id
    WHERE ultp.completed_at IS NULL -- Only active enrollments
      AND lt.status = 'published'
      AND COALESCE(ep.email_enabled, true) = true -- Email enabled globally
  ),
  track_lessons AS (
    -- Get all lessons in learning tracks with their order
    SELECT 
      ltl.learning_track_id,
      ltl.lesson_id,
      ltl.order_index,
      l.title::TEXT as lesson_title,
      l.description::TEXT as lesson_description,
      l.status as lesson_status
    FROM public.learning_track_lessons ltl
    INNER JOIN public.lessons l ON ltl.lesson_id = l.id
    WHERE l.status = 'published'
  ),
  lesson_availability AS (
    -- Calculate lesson availability for each user
    -- This is a simplified version - you may need to adjust based on your scheduling logic
    SELECT 
      ut.user_id,
      ut.user_email as email,
      tl.lesson_id,
      tl.lesson_title,
      tl.lesson_description,
      ut.learning_track_id,
      ut.track_title,
      tl.order_index,
      CASE 
        -- If all lessons are available immediately
        WHEN ut.allow_all_lessons_immediately THEN CURRENT_DATE
        -- If fixed dates schedule
        WHEN ut.schedule_type = 'fixed_dates' AND ut.start_date IS NOT NULL THEN
          ut.start_date::DATE
        -- If duration based schedule
        WHEN ut.schedule_type = 'duration_based' AND ut.lessons_per_week > 0 THEN
          (ut.enrolled_at::DATE + (tl.order_index / ut.lessons_per_week * 7)::INTEGER)
        -- Default to enrollment date
        ELSE ut.enrolled_at::DATE
      END as available_date
    FROM user_tracks ut
    INNER JOIN track_lessons tl ON ut.learning_track_id = tl.learning_track_id
    LEFT JOIN public.user_lesson_progress ulp ON 
      ulp.user_id = ut.user_id AND ulp.lesson_id = tl.lesson_id
    WHERE ulp.completed_at IS NULL -- Lesson not yet completed
  )
  SELECT DISTINCT
    la.user_id,
    la.email,
    la.lesson_id,
    la.lesson_title,
    la.lesson_description,
    la.learning_track_id,
    la.track_title,
    la.available_date,
    la.order_index,
    CASE
      -- Lesson is available now and not completed
      WHEN la.available_date <= CURRENT_DATE THEN 'available_now'
      -- Lesson becomes available soon (within 3 days)
      WHEN la.available_date <= CURRENT_DATE + INTERVAL '3 days' THEN 'available_soon'
      ELSE 'not_yet'
    END as reminder_type
  FROM lesson_availability la
  LEFT JOIN public.lesson_reminder_history lrh ON
    lrh.user_id = la.user_id
    AND lrh.lesson_id = la.lesson_id
    AND lrh.available_date = la.available_date
    AND lrh.sent_at > NOW() - INTERVAL '24 hours' -- Don't send more than once per day
  WHERE lrh.id IS NULL -- No reminder sent in last 24 hours
    AND (
      la.available_date <= CURRENT_DATE -- Available now
      OR la.available_date <= CURRENT_DATE + INTERVAL '3 days' -- Available soon
    )
  ORDER BY la.available_date, la.order_index;
END;
$$;


--
-- Name: FUNCTION get_users_needing_lesson_reminders(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_users_needing_lesson_reminders() IS 'Returns list of users who need lesson reminders. Uses 7-day intervals with max 3 reminders per lesson';


--
-- Name: handle_department_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_department_assignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    PERFORM public.generate_learning_track_assignments(NEW.learning_track_id);
    RETURN NEW;
END;
$$;


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  base_username text;
  final_username text;
  final_employee_id text;
  counter integer;
  user_access_level text;
  assigned_role app_role;
BEGIN
  -- Validate that app_role type exists and is accessible
  -- This will fail early if there are permission issues
  SELECT 'user'::app_role INTO assigned_role;
  
  -- Generate base username from metadata or email
  base_username := COALESCE(
    NEW.email,  -- Changed: Use full email directly
    NEW.raw_user_meta_data ->> 'username',
    'user'
  );
  
  -- Ensure username is unique
  final_username := base_username;
  counter := 0;
  
  WHILE EXISTS(SELECT 1 FROM public.profiles WHERE username = final_username) LOOP
    counter := counter + 1;
    final_username := base_username || counter::text;
    
    -- Safety break to prevent infinite loops
    IF counter > 999 THEN
      final_username := base_username || extract(epoch from now())::text;
      EXIT;
    END IF;
  END LOOP;
  
  -- Generate unique employee_id if not provided
  final_employee_id := COALESCE(
    NEW.raw_user_meta_data ->> 'employee_id',
    'EMP-' || EXTRACT(YEAR FROM NOW()) || '-' || 
    LPAD(EXTRACT(DOY FROM NOW())::text, 3, '0') || '-' || 
    UPPER(SUBSTR(NEW.id::text, 1, 6))
  );
  
  -- Get access level to determine role
  user_access_level := COALESCE(NEW.raw_user_meta_data ->> 'access_level', 'User');
  
  -- Role mapping for user_roles table
  CASE user_access_level
    WHEN 'Super Admin' THEN assigned_role := 'super_admin';
    WHEN 'Admin' THEN assigned_role := 'super_admin';
    WHEN 'Client Admin' THEN assigned_role := 'client_admin';
    WHEN 'Author' THEN assigned_role := 'Author';
    WHEN 'Manager' THEN assigned_role := 'manager';
    ELSE assigned_role := 'user';
  END CASE;
  
  -- Validate location_id if provided - CHECK AGAINST LOCATIONS TABLE
  IF NEW.raw_user_meta_data ->> 'location_id' IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.locations 
      WHERE id = (NEW.raw_user_meta_data ->> 'location_id')::uuid
    ) THEN
      RAISE LOG 'Invalid location_id provided: %, creating user without location', 
        NEW.raw_user_meta_data ->> 'location_id';
      -- Continue without location_id rather than failing
    END IF;
  END IF;
  
  -- Insert profile with validation (removed access_level column)
  INSERT INTO public.profiles (
    id, 
    full_name, 
    first_name,
    last_name,
    username,
    status,
    employee_id,
    phone,
    location,
    location_id,
    bio,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'first_name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'last_name', ''),
    final_username,
    'Pending',
    final_employee_id,
    COALESCE(NEW.raw_user_meta_data ->> 'phone', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'location', ''),
    CASE 
      WHEN NEW.raw_user_meta_data ->> 'location_id' IS NOT NULL 
        AND EXISTS (
          SELECT 1 FROM public.locations 
          WHERE id = (NEW.raw_user_meta_data ->> 'location_id')::uuid
        )
      THEN (NEW.raw_user_meta_data ->> 'location_id')::uuid 
      ELSE NULL 
    END,
    COALESCE(NEW.raw_user_meta_data ->> 'bio', ''),
    NOW(),
    NOW()
  );
  
  -- Insert into user_roles table with appropriate role
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, assigned_role)
  ON CONFLICT (user_id) DO UPDATE SET role = assigned_role;
  
  RAISE LOG 'Successfully created profile for user % with username % and role %', 
    NEW.id, final_username, assigned_role;
  
  RETURN NEW;
EXCEPTION
  -- Only catch specific expected errors, let critical ones bubble up
  WHEN unique_violation THEN
    RAISE LOG 'Unique violation creating profile for user %: %', NEW.id, SQLERRM;
    -- Try to continue with a different username
    final_username := base_username || extract(epoch from now())::text;
    
    -- Retry the insert with a timestamp-based username (removed access_level column)
    INSERT INTO public.profiles (
      id, full_name, first_name, last_name, username, status, employee_id,
      phone, location, location_id, bio, created_at, updated_at
    )
    VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''),
      COALESCE(NEW.raw_user_meta_data ->> 'first_name', ''),
      COALESCE(NEW.raw_user_meta_data ->> 'last_name', ''),
      final_username,
      'Pending',
      final_employee_id,
      COALESCE(NEW.raw_user_meta_data ->> 'phone', ''),
      COALESCE(NEW.raw_user_meta_data ->> 'location', ''),
      CASE 
        WHEN NEW.raw_user_meta_data ->> 'location_id' IS NOT NULL 
          AND EXISTS (
            SELECT 1 FROM public.locations 
            WHERE id = (NEW.raw_user_meta_data ->> 'location_id')::uuid
          )
        THEN (NEW.raw_user_meta_data ->> 'location_id')::uuid 
        ELSE NULL 
      END,
      COALESCE(NEW.raw_user_meta_data ->> 'bio', ''),
      NOW(),
      NOW()
    );
    
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, assigned_role)
    ON CONFLICT (user_id) DO UPDATE SET role = assigned_role;
    
    RETURN NEW;
  WHEN OTHERS THEN
    -- Log the error but let it bubble up to fail user creation
    RAISE LOG 'Critical error creating profile for user %: % - %', NEW.id, SQLSTATE, SQLERRM;
    RAISE;
END;$$;


--
-- Name: handle_profile_activation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_profile_activation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- When profile status changes to Active, update account_inventory
  IF NEW.status = 'Active' AND OLD.status != 'Active' THEN
    UPDATE public.account_inventory
    SET 
      status = 'Active',
      modified_at = NOW(),
      modified_by = NEW.id -- use uuid, not text
    WHERE user_id = NEW.id
      AND status = 'Pending';
  END IF;
  
  RETURN NEW;
END;
$$;


--
-- Name: handle_profile_deletion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_profile_deletion() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Update all account_inventory records for this user
  UPDATE public.account_inventory
  SET 
    status = 'Inactive',
    date_access_revoked = CURRENT_DATE,
    modified_at = NOW(),
    modified_by = OLD.id -- use uuid, not text
  WHERE user_id = OLD.id
    AND status != 'Inactive';
  
  RETURN OLD;
END;
$$;


--
-- Name: handle_role_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_role_assignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    PERFORM public.generate_learning_track_assignments(NEW.learning_track_id);
    RETURN NEW;
END;
$$;


--
-- Name: has_role(uuid, public.app_role); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_role(_user_id uuid, _role public.app_role) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  target_user_id uuid := _user_id;
  target_role app_role := _role;
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.user_roles ur
    WHERE ur.user_id = target_user_id
      AND ur.role = target_role
  );
END;
$$;


--
-- Name: is_user_in_managed_department(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_user_in_managed_department(_manager_id uuid, _user_id uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM user_departments ud
    WHERE ud.user_id = _user_id
      AND ud.is_primary = true
      AND ud.department_id IN (
        SELECT id FROM departments WHERE manager_id = _manager_id
      )
  );
END;
$$;


--
-- Name: mark_lesson_translations_outdated_manual(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_lesson_translations_outdated_manual(lesson_uuid uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Mark all lesson translations as outdated
  UPDATE lesson_translations 
  SET is_outdated = TRUE, updated_at = NOW()
  WHERE lesson_id = lesson_uuid;
  
  -- Mark all node translations as outdated
  UPDATE lesson_node_translations 
  SET is_outdated = TRUE, updated_at = NOW()
  WHERE node_id IN (
    SELECT id FROM lesson_nodes WHERE lesson_id = lesson_uuid
  );
  
  RAISE NOTICE 'Marked all translations as outdated for lesson %', lesson_uuid;
END;
$$;


--
-- Name: mark_node_translations_outdated(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_node_translations_outdated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Mark node translations as outdated when node is updated
  UPDATE public.lesson_node_translations 
  SET is_outdated = TRUE 
  WHERE node_id = NEW.id;
  
  RETURN NEW;
END;
$$;


--
-- Name: mark_translations_outdated(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_translations_outdated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Mark lesson translations as outdated when lesson is updated
  UPDATE public.lesson_translations 
  SET is_outdated = TRUE 
  WHERE lesson_id = NEW.id;
  
  -- Mark node translations as outdated when lesson nodes are updated
  UPDATE public.lesson_node_translations 
  SET is_outdated = TRUE 
  WHERE node_id IN (
    SELECT id FROM public.lesson_nodes WHERE lesson_id = NEW.id
  );
  
  RETURN NEW;
END;
$$;


--
-- Name: prevent_license_over_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_license_over_assignment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$BEGIN
  IF (
    (SELECT COUNT(*) FROM user_product_licenses WHERE license_id = NEW.license_id)
    >= (SELECT seats FROM customer_product_licenses WHERE id = NEW.license_id)
  )
  THEN
    RAISE EXCEPTION 'License limit exceeded';
  END IF;
  RETURN NEW;
END;$$;


--
-- Name: protect_system_breach_roles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_system_breach_roles() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Prevent updates to system roles
  IF TG_OP = 'UPDATE' AND OLD.is_system = true THEN
    -- Allow only member assignment changes
    IF NEW.member IS DISTINCT FROM OLD.member THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Cannot modify system breach management roles';
  END IF;
  
  -- Prevent deletion of system roles
  IF TG_OP = 'DELETE' AND OLD.is_system = true THEN
    RAISE EXCEPTION 'Cannot delete system breach management roles';
  END IF;
  
  RETURN COALESCE(NEW, OLD);
END;
$$;


--
-- Name: refresh_outdated_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_outdated_status() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Mark all translations as outdated where lesson was modified after translation
  UPDATE lesson_translations 
  SET is_outdated = TRUE
  WHERE lesson_id IN (
    SELECT l.id 
    FROM lessons l 
    WHERE l.updated_at > lesson_translations.updated_at
  );
  
  -- Mark all node translations as outdated where node was modified after translation
  UPDATE lesson_node_translations 
  SET is_outdated = TRUE
  WHERE node_id IN (
    SELECT ln.id 
    FROM lesson_nodes ln 
    WHERE ln.updated_at > lesson_node_translations.updated_at
  );
  
  RAISE NOTICE 'Refreshed outdated status for all translations';
END;
$$;


--
-- Name: send_email_notification(uuid, text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_email_notification(p_user_id uuid, p_type text, p_title text, p_message text, p_email text, p_scheduled_for timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  notification_id UUID;
BEGIN
  -- Insert the notification
  INSERT INTO email_notifications (
    user_id,
    type,
    title,
    message,
    email,
    scheduled_for
  ) VALUES (
    p_user_id,
    p_type,
    p_title,
    p_message,
    p_email,
    COALESCE(p_scheduled_for, NOW())
  ) RETURNING id INTO notification_id;

  -- TODO: Implement actual email sending logic here
  -- This could integrate with services like:
  -- - Supabase Edge Functions
  -- - Resend.com
  -- - SendGrid
  -- - AWS SES
  -- - etc.

  RETURN notification_id;
END;
$$;


--
-- Name: should_send_notification(uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.should_send_notification(p_user_id uuid, p_notification_type text, p_rule_id uuid) RETURNS TABLE(should_send boolean, skip_reason text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_email_enabled BOOLEAN;
  v_type_enabled BOOLEAN;
  v_quiet_hours_enabled BOOLEAN;
  v_quiet_start TIME;
  v_quiet_end TIME;
  v_current_time TIME;
  v_cooldown_hours INTEGER;
  v_last_notification TIMESTAMP;
  v_max_per_day INTEGER;
  v_today_count INTEGER;
BEGIN
  -- Check email_preferences
  SELECT 
    COALESCE(email_enabled, true),
    CASE 
      WHEN p_notification_type IN ('lesson_reminder', 'lesson_completed') 
        THEN COALESCE(lesson_reminders, true)
      WHEN p_notification_type IN ('assignment_due', 'assignment_overdue') 
        THEN COALESCE(task_due_dates, true)
      WHEN p_notification_type LIKE 'track_milestone%' 
        THEN COALESCE(course_completions, true)
      WHEN p_notification_type LIKE 'quiz_%' 
        THEN COALESCE(lesson_reminders, true)
      ELSE true
    END,
    COALESCE(quiet_hours_enabled, false),
    quiet_hours_start,
    quiet_hours_end
  INTO
    v_email_enabled,
    v_type_enabled,
    v_quiet_hours_enabled,
    v_quiet_start,
    v_quiet_end
  FROM public.email_preferences
  WHERE user_id = p_user_id;
  
  -- Default to enabled if no preferences found
  v_email_enabled := COALESCE(v_email_enabled, true);
  v_type_enabled := COALESCE(v_type_enabled, true);
  
  -- Check global email disabled
  IF NOT v_email_enabled THEN
    RETURN QUERY SELECT false, 'email_disabled';
    RETURN;
  END IF;
  
  -- Check type-specific preference
  IF NOT v_type_enabled THEN
    RETURN QUERY SELECT false, 'notification_type_disabled';
    RETURN;
  END IF;
  
  -- Check quiet hours
  IF v_quiet_hours_enabled AND v_quiet_start IS NOT NULL AND v_quiet_end IS NOT NULL THEN
    v_current_time := LOCALTIME;
    
    IF v_quiet_start < v_quiet_end THEN
      -- Normal case: e.g., 22:00 to 07:00
      IF v_current_time >= v_quiet_start AND v_current_time < v_quiet_end THEN
        RETURN QUERY SELECT false, 'quiet_hours_active';
        RETURN;
      END IF;
    ELSE
      -- Spans midnight: e.g., 22:00 to 07:00
      IF v_current_time >= v_quiet_start OR v_current_time < v_quiet_end THEN
        RETURN QUERY SELECT false, 'quiet_hours_active';
        RETURN;
      END IF;
    END IF;
  END IF;
  
  -- Check rule cooldown
  SELECT cooldown_hours, max_sends_per_user_per_day
  INTO v_cooldown_hours, v_max_per_day
  FROM public.notification_rules
  WHERE id = p_rule_id;
  
  IF v_cooldown_hours IS NOT NULL THEN
    SELECT MAX(created_at)
    INTO v_last_notification
    FROM public.notification_history
    WHERE user_id = p_user_id
      AND rule_id = p_rule_id
      AND status = 'sent';
    
    IF v_last_notification IS NOT NULL 
       AND v_last_notification > NOW() - (v_cooldown_hours || ' hours')::INTERVAL THEN
      RETURN QUERY SELECT false, 'cooldown_period';
      RETURN;
    END IF;
  END IF;
  
  -- Check rate limit
  IF v_max_per_day IS NOT NULL THEN
    SELECT COUNT(*)
    INTO v_today_count
    FROM public.notification_history
    WHERE user_id = p_user_id
      AND rule_id = p_rule_id
      AND status = 'sent'
      AND created_at >= CURRENT_DATE;
    
    IF v_today_count >= v_max_per_day THEN
      RETURN QUERY SELECT false, 'rate_limit_exceeded';
      RETURN;
    END IF;
  END IF;
  
  -- All checks passed
  RETURN QUERY SELECT true, NULL::TEXT;
  RETURN;
END;
$$;


--
-- Name: track_lesson_changes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.track_lesson_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
  affected_count INTEGER;
  estimated_cost DECIMAL(8,4);
BEGIN
  -- Only track significant fields
  IF TG_OP = 'UPDATE' AND (
    OLD.title IS DISTINCT FROM NEW.title OR
    OLD.description IS DISTINCT FROM NEW.description
  ) THEN
  
    -- Count affected translations
    SELECT COUNT(*) INTO affected_count
    FROM lesson_translations
    WHERE lesson_id = NEW.id;
    
    -- Estimate retranslation cost (rough estimate: $0.02 per 1000 chars)
    estimated_cost := (
      COALESCE(LENGTH(NEW.title), 0) + 
      COALESCE(LENGTH(NEW.description), 0)
    ) * 0.00002 * affected_count;
    
    -- Log title changes
    IF OLD.title IS DISTINCT FROM NEW.title THEN
      INSERT INTO translation_change_log (
        table_name, record_id, lesson_id, field_name,
        old_value, new_value, old_hash, new_hash,
        change_type, change_magnitude, character_difference,
        updated_by, affected_translations, estimated_retranslation_cost
      ) VALUES (
        'lessons', NEW.id::TEXT, NEW.id, 'title',
        OLD.title, NEW.title,
        generate_content_hash(COALESCE(OLD.title, '')),
        generate_content_hash(COALESCE(NEW.title, '')),
        'updated',
        'moderate', -- Simplified change magnitude
        ABS(LENGTH(COALESCE(NEW.title, '')) - LENGTH(COALESCE(OLD.title, ''))),
        NEW.updated_by,
        affected_count,
        estimated_cost * 0.3 -- Title is smaller portion
      );
    END IF;
    
    -- Log description changes  
    IF OLD.description IS DISTINCT FROM NEW.description THEN
      INSERT INTO translation_change_log (
        table_name, record_id, lesson_id, field_name,
        old_value, new_value, old_hash, new_hash,
        change_type, change_magnitude, character_difference,
        updated_by, affected_translations, estimated_retranslation_cost
      ) VALUES (
        'lessons', NEW.id::TEXT, NEW.id, 'description',
        OLD.description, NEW.description,
        generate_content_hash(COALESCE(OLD.description, '')),
        generate_content_hash(COALESCE(NEW.description, '')),
        'updated',
        'moderate', -- Simplified change magnitude
        ABS(LENGTH(COALESCE(NEW.description, '')) - LENGTH(COALESCE(OLD.description, ''))),
        NEW.updated_by,
        affected_count,
        estimated_cost * 0.7 -- Description is larger portion
      );
    END IF;
    
    -- Mark existing translations as potentially outdated
    UPDATE lesson_translations 
    SET 
      is_outdated = true,
      updated_at = NOW()
    WHERE lesson_id = NEW.id;
    
    -- Update lesson metadata
    NEW.updated_at := NOW();
  END IF;
  
  RETURN NEW;
END;
$_$;


--
-- Name: track_lesson_node_changes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.track_lesson_node_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  affected_count INTEGER;
  estimated_cost DECIMAL(8,4);
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content THEN
  
    -- Count affected translations for this node
    SELECT COUNT(*) INTO affected_count
    FROM lesson_node_translations
    WHERE node_id = NEW.id;
    
    -- Estimate cost
    estimated_cost := LENGTH(COALESCE(NEW.content, '')) * 0.00002 * affected_count;
    
    -- Log the change
    INSERT INTO translation_change_log (
      table_name, record_id, lesson_id, field_name,
      old_value, new_value, old_hash, new_hash,
      change_type, change_magnitude, character_difference,
      updated_by, affected_translations, estimated_retranslation_cost
    ) VALUES (
      'lesson_nodes', NEW.id, NEW.lesson_id, 'content',
      OLD.content, NEW.content,
      generate_content_hash(COALESCE(OLD.content, '')),
      generate_content_hash(COALESCE(NEW.content, '')),
      'updated',
      'moderate', -- Simplified change magnitude
      ABS(LENGTH(COALESCE(NEW.content, '')) - LENGTH(COALESCE(OLD.content, ''))),
      NULL, -- lesson_nodes might not have updated_by
      affected_count,
      estimated_cost
    );
    
    -- Mark translations as outdated
    UPDATE lesson_node_translations 
    SET 
      is_outdated = true,
      updated_at = NOW()
    WHERE node_id = NEW.id;
    
    -- Update node metadata
    NEW.content_hash := generate_content_hash(COALESCE(NEW.content, ''));
    NEW.updated_at := NOW();
  END IF;
  
  RETURN NEW;
END;
$$;


--
-- Name: trigger_generate_assignments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trigger_generate_assignments() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.generate_document_assignments(NEW.document_id);
    RETURN NEW;
END;
$$;


--
-- Name: trigger_lesson_reminders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trigger_lesson_reminders() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  user_id UUID;
  result jsonb;
BEGIN
  -- Get current user ID
  user_id := auth.uid();
  
  -- Check if user is a super_admin or client_admin
  IF NOT (
    has_role(user_id, 'super_admin'::app_role) OR 
    has_role(user_id, 'client_admin'::app_role)
  ) THEN
    RAISE EXCEPTION 'Only administrators (super_admin or client_admin) can trigger lesson reminders';
  END IF;

  -- For now, just return a success message
  -- The actual lesson reminder logic should be handled by the Edge Function
  -- when called directly from the UI
  result := jsonb_build_object(
    'success', true,
    'message', 'Lesson reminder trigger authorized. Please call the send-lesson-reminders Edge Function directly.',
    'timestamp', NOW(),
    'triggered_by', user_id
  );

  RETURN result;
END;
$$;


--
-- Name: FUNCTION trigger_lesson_reminders(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.trigger_lesson_reminders() IS 'Manually trigger lesson reminder sending (admin only)';


--
-- Name: update_email_layout_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_email_layout_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: update_email_preferences_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_email_preferences_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  -- If updated_by is not set, set it to the current user
  IF NEW.updated_by IS NULL AND auth.uid() IS NOT NULL THEN
    NEW.updated_by = auth.uid();
  END IF;
  -- If created_by is not set, set it to the current user
  IF NEW.created_by IS NULL AND auth.uid() IS NOT NULL THEN
    NEW.created_by = auth.uid();
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: update_email_templates_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_email_templates_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: update_node_content_hash(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_node_content_hash() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.content_hash = generate_content_hash(NEW.content, NEW.media_alt);
  RETURN NEW;
END;
$$;


--
-- Name: update_notification_preferences_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_notification_preferences_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: update_notification_rule_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_notification_rule_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: update_translation_content_hash(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_translation_content_hash() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.content_hash = generate_content_hash(NEW.content_translated, NEW.media_alt_translated);
  RETURN NEW;
END;
$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_inventory (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name text NOT NULL,
    username_email text NOT NULL,
    software text,
    department text,
    role_account_type text,
    data_class text,
    approval_status text DEFAULT 'Not submitted'::text,
    authorized_by uuid,
    date_access_created timestamp with time zone,
    date_access_revoked timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    modified_at timestamp with time zone DEFAULT now(),
    status text DEFAULT 'Pending'::text,
    user_id uuid,
    created_by uuid DEFAULT auth.uid(),
    modified_by uuid,
    CONSTRAINT account_inventory_status_check CHECK ((status = ANY (ARRAY['Pending'::text, 'Active'::text, 'Inactive'::text, 'OnLeave'::text])))
);


--
-- Name: COLUMN account_inventory.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.account_inventory.user_id IS 'User ID preserved for audit trail. May reference deleted users. Cross-reference with user_deletion_audit table.';


--
-- Name: COLUMN account_inventory.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.account_inventory.created_by IS 'UUID of the user who created this account record (either via bulk upload or manual creation).';


--
-- Name: breach_management_team; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.breach_management_team (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    team_role text,
    recommended_designee text,
    activity text,
    best_practice text,
    org_practice text,
    member uuid,
    mandatory boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    sequence integer DEFAULT 0 NOT NULL,
    allow_custom boolean DEFAULT false NOT NULL,
    is_system boolean DEFAULT false NOT NULL
);


--
-- Name: breach_team_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.breach_team_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    breach_team_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid,
    department_id uuid,
    is_primary boolean DEFAULT false NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_system boolean DEFAULT false NOT NULL
);


--
-- Name: certificates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.certificates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    issued_by text NOT NULL,
    date_acquired timestamp with time zone NOT NULL,
    expiry_date timestamp with time zone,
    credential_id text,
    status text DEFAULT 'Valid'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    type text DEFAULT 'Certificate'::text NOT NULL,
    org_cert boolean DEFAULT false,
    CONSTRAINT certificates_status_check CHECK ((status = ANY (ARRAY['Valid'::text, 'Expired'::text, 'Pending'::text]))),
    CONSTRAINT certificates_type_check CHECK ((type = ANY (ARRAY['Certificate'::text, 'Document'::text])))
);


--
-- Name: COLUMN certificates.org_cert; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.certificates.org_cert IS 'org_level if true, false otherwise';


--
-- Name: csba_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.csba_answers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assessment_date timestamp without time zone NOT NULL,
    answer integer NOT NULL,
    CONSTRAINT csba_answers_answer_check CHECK (((answer >= 0) AND (answer <= 10)))
);


--
-- Name: csba_master; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.csba_master (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    question_id uuid DEFAULT gen_random_uuid() NOT NULL,
    question text,
    domain text,
    domain_short text,
    type text,
    recommendation text
);


--
-- Name: TABLE csba_master; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.csba_master IS 'Master Table with questions, domains and recommendations';


--
-- Name: csba_assessment_summary_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.csba_assessment_summary_view WITH (security_invoker='true') AS
 SELECT cm.question_id,
    avg((ca.answer)::numeric) AS avg_score,
    count(ca.answer) AS num_responses,
    cm.question,
    cm.type,
    cm.domain_short,
    cm.recommendation,
    cm.domain
   FROM (public.csba_master cm
     LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
  GROUP BY cm.question_id, cm.question, cm.type, cm.domain_short, cm.recommendation, cm.domain;


--
-- Name: csba_detailed_insights_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.csba_detailed_insights_view WITH (security_invoker='true') AS
 SELECT cm.recommendation,
    cm.domain,
    avg((ca.answer)::numeric) AS avg_score,
    cm.question,
    cm.domain_short
   FROM (public.csba_master cm
     LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
  GROUP BY cm.recommendation, cm.domain, cm.question, cm.domain_short
 HAVING (avg((ca.answer)::numeric) < 3.0)
  ORDER BY (avg((ca.answer)::numeric));


--
-- Name: csba_domain_score_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.csba_domain_score_view WITH (security_invoker='true') AS
 SELECT cm.domain,
    cm.domain_short,
    avg((ca.answer)::numeric) AS domain_avg,
    sum((ca.answer)::numeric) AS weighted_score,
    round(((avg((ca.answer)::numeric) / 5.0) * (100)::numeric), 1) AS weighted_percent,
    stddev((ca.answer)::numeric) AS std_deviation,
        CASE
            WHEN (avg((ca.answer)::numeric) < 2.0) THEN 1
            WHEN (avg((ca.answer)::numeric) < 3.0) THEN 2
            WHEN (avg((ca.answer)::numeric) < 4.0) THEN 3
            ELSE 4
        END AS priority
   FROM (public.csba_master cm
     LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
  GROUP BY cm.domain, cm.domain_short
  ORDER BY (avg((ca.answer)::numeric));


--
-- Name: csba_key_insights_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.csba_key_insights_view WITH (security_invoker='true') AS
 SELECT row_number() OVER (ORDER BY avg_score) AS n,
    domain,
        CASE
            WHEN (avg_score < 2.0) THEN (('Critical security gaps identified in '::text || domain) || ' domain'::text)
            WHEN (avg_score < 3.0) THEN (('Significant improvements needed in '::text || domain) || ' domain'::text)
            WHEN (avg_score < 4.0) THEN (('Moderate risk areas found in '::text || domain) || ' domain'::text)
            ELSE (('Well-managed '::text || domain) || ' domain with minor improvements possible'::text)
        END AS insight
   FROM ( SELECT cm.domain,
            avg((ca.answer)::numeric) AS avg_score
           FROM (public.csba_master cm
             LEFT JOIN public.csba_answers ca ON ((cm.question_id = ca.question_id)))
          GROUP BY cm.domain
         HAVING (count(ca.answer) > 0)) domain_scores
  ORDER BY avg_score
 LIMIT 5;


--
-- Name: customer_product_licenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_product_licenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    product_id uuid NOT NULL,
    language text NOT NULL,
    seats integer NOT NULL,
    start_date timestamp with time zone,
    term integer NOT NULL,
    end_date timestamp with time zone
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_name text NOT NULL,
    short_name text NOT NULL,
    is_active boolean,
    primary_contact text,
    email text,
    endpoints integer
);


--
-- Name: notification_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    email_template_id uuid,
    rule_id uuid,
    trigger_event text NOT NULL,
    template_variables jsonb,
    status text DEFAULT 'pending'::text,
    sent_at timestamp with time zone,
    error_message text,
    skip_reason text,
    priority text,
    channel text DEFAULT 'email'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE notification_history; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.notification_history IS 'Complete audit trail of all notification attempts. Links to email_templates and notification_rules. Primary table for notification tracking.';


--
-- Name: COLUMN notification_history.email_template_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notification_history.email_template_id IS 'References email_templates - which template was used';


--
-- Name: COLUMN notification_history.template_variables; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notification_history.template_variables IS 'JSON snapshot of variables used to populate this notification';


--
-- Name: daily_notification_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.daily_notification_summary AS
 SELECT date(created_at) AS notification_date,
    trigger_event,
    status,
    count(*) AS count,
    count(DISTINCT user_id) AS unique_users
   FROM public.notification_history
  WHERE (created_at >= (CURRENT_DATE - '30 days'::interval))
  GROUP BY (date(created_at)), trigger_event, status
  ORDER BY (date(created_at)) DESC, trigger_event;


--
-- Name: departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.departments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    manager_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: document_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_assignments (
    assignment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    document_id uuid NOT NULL,
    document_version integer NOT NULL,
    assigned_by uuid,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    due_date date,
    status text DEFAULT 'Not started'::text NOT NULL,
    completed_at timestamp with time zone,
    reminder_sent boolean DEFAULT false NOT NULL,
    notes text,
    CONSTRAINT document_assignments_status_check CHECK ((status = ANY (ARRAY['Not started'::text, 'In progress'::text, 'Completed'::text])))
);


--
-- Name: document_departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_departments (
    document_id uuid NOT NULL,
    department_id uuid NOT NULL
);


--
-- Name: document_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_roles (
    document_id uuid NOT NULL,
    role_id uuid NOT NULL
);


--
-- Name: document_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_users (
    document_id uuid NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    document_id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    description text,
    category text,
    required boolean DEFAULT false NOT NULL,
    url text,
    file_name text,
    file_type text,
    version integer DEFAULT 1 NOT NULL,
    due_days integer DEFAULT 30,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_layouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_layouts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    is_default boolean DEFAULT false,
    is_system boolean DEFAULT false,
    html_layout text NOT NULL,
    layout_variables jsonb DEFAULT '[]'::jsonb,
    brand_colors jsonb DEFAULT '{}'::jsonb,
    is_active boolean DEFAULT true,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    last_used_at timestamp with time zone
);


--
-- Name: TABLE email_layouts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.email_layouts IS 'Reusable email layouts that provide consistent branding across all notifications';


--
-- Name: COLUMN email_layouts.is_system; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_layouts.is_system IS 'System layouts cannot be deleted, only edited. Custom layouts can be fully managed.';


--
-- Name: COLUMN email_layouts.html_layout; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_layouts.html_layout IS 'Full HTML email wrapper with {{email_content}} placeholder for template content';


--
-- Name: COLUMN email_layouts.brand_colors; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_layouts.brand_colors IS 'JSON object with brand colors for easy customization without editing HTML';


--
-- Name: email_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    title text NOT NULL,
    message text NOT NULL,
    email text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    scheduled_for timestamp with time zone,
    sent_at timestamp with time zone,
    error_message text,
    retry_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT email_notifications_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'failed'::text]))),
    CONSTRAINT email_notifications_type_check CHECK ((type = ANY (ARRAY['lesson_reminder'::text, 'task_due'::text, 'system_alert'::text, 'achievement'::text, 'course_completion'::text])))
);


--
-- Name: TABLE email_notifications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.email_notifications IS 'Legacy table - data migrated to notification_history on 2025-01-14';


--
-- Name: email_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    email_enabled boolean DEFAULT true,
    task_due_dates boolean DEFAULT true,
    system_alerts boolean DEFAULT false,
    achievements boolean DEFAULT true,
    course_completions boolean DEFAULT true,
    quiet_hours_enabled boolean DEFAULT false,
    quiet_hours_start_time time without time zone DEFAULT '22:00:00'::time without time zone,
    quiet_hours_end_time time without time zone DEFAULT '08:00:00'::time without time zone,
    reminder_days_before integer DEFAULT 0,
    reminder_time time without time zone DEFAULT '09:00:00'::time without time zone,
    include_upcoming_lessons boolean DEFAULT true,
    upcoming_days_ahead integer DEFAULT 3,
    max_reminder_attempts integer DEFAULT 3,
    reminder_frequency_days integer DEFAULT 7,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by uuid,
    updated_by uuid
);


--
-- Name: TABLE email_preferences; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.email_preferences IS 'Email notification preferences - org-level (user_id=NULL) or user-level (user_id=user)';


--
-- Name: COLUMN email_preferences.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.user_id IS 'NULL for org-level settings, user UUID for user-level overrides';


--
-- Name: COLUMN email_preferences.reminder_days_before; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.reminder_days_before IS 'Days before lesson to send reminder (0 = same day)';


--
-- Name: COLUMN email_preferences.reminder_time; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.reminder_time IS 'Time of day to send lesson reminders';


--
-- Name: COLUMN email_preferences.include_upcoming_lessons; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.include_upcoming_lessons IS 'Include upcoming lessons in reminder emails';


--
-- Name: COLUMN email_preferences.upcoming_days_ahead; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.upcoming_days_ahead IS 'How many days ahead to look for upcoming lessons';


--
-- Name: COLUMN email_preferences.max_reminder_attempts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.max_reminder_attempts IS 'Maximum number of reminder attempts per lesson';


--
-- Name: COLUMN email_preferences.reminder_frequency_days; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.reminder_frequency_days IS 'Days between reminder attempts';


--
-- Name: COLUMN email_preferences.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.created_by IS 'User who created this preference record';


--
-- Name: COLUMN email_preferences.updated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_preferences.updated_by IS 'User who last updated this preference record';


--
-- Name: email_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(100) NOT NULL,
    subject_template text NOT NULL,
    html_body_template text NOT NULL,
    text_body_template text,
    variables jsonb DEFAULT '[]'::jsonb,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    system boolean DEFAULT true NOT NULL,
    is_system boolean DEFAULT false,
    category text DEFAULT 'learning_progress'::text,
    default_priority text DEFAULT 'normal'::text,
    created_by uuid,
    use_count integer DEFAULT 0,
    last_used_at timestamp with time zone,
    layout_id uuid,
    description text
);


--
-- Name: TABLE email_templates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.email_templates IS 'Email notification templates. System templates (is_system=true) cannot be deleted by admins, only edited.';


--
-- Name: COLUMN email_templates.html_body_template; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_templates.html_body_template IS 'Template content only (no header/footer). Gets injected into {{email_content}} in the layout.';


--
-- Name: COLUMN email_templates.variables; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_templates.variables IS 'JSON array documenting available variables for this template, used by template editor UI';


--
-- Name: COLUMN email_templates.is_system; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_templates.is_system IS 'System templates cannot be deleted, only content can be edited. Custom templates can be fully managed.';


--
-- Name: COLUMN email_templates.category; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.email_templates.category IS 'Groups templates for UI organization: learning_progress, gamification, system, custom';


--
-- Name: hardware; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hardware (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    model text NOT NULL,
    serial_number text NOT NULL,
    status text DEFAULT 'Active'::text NOT NULL,
    assigned_date timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hardware_status_check CHECK ((status = ANY (ARRAY['Active'::text, 'Maintenance'::text, 'End-of-life'::text])))
);


--
-- Name: hardware_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hardware_inventory (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    asset_owner text NOT NULL,
    device_name text NOT NULL,
    serial_number text NOT NULL,
    asset_type text NOT NULL,
    asset_location text,
    owner text,
    asset_classification text,
    end_of_support_date date,
    os_edition text,
    os_version text,
    approval_status text DEFAULT 'Not submitted'::text,
    approval_authorized_by text,
    approvers text,
    responses text,
    approval_created_date timestamp with time zone,
    status text DEFAULT 'Active'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    manufacturer text,
    model text
);


--
-- Name: hib_checklist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hib_checklist (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    hib_section text NOT NULL,
    hib_clause integer NOT NULL,
    hib_clause_description text,
    implementation_status text,
    remarks text,
    additional_information_i text,
    additional_information_ii text,
    additional_information_iii text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    section_number integer,
    suggested_artefacts text,
    CONSTRAINT hib_checklist_implementation_status_check CHECK ((implementation_status = ANY (ARRAY['No'::text, 'Yes'::text, 'Partially'::text, ''::text])))
);


--
-- Name: hib_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hib_results (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    section_name text NOT NULL,
    section_number integer NOT NULL,
    total integer DEFAULT 0 NOT NULL,
    implemented integer DEFAULT 0 NOT NULL,
    not_implemented integer DEFAULT 0 NOT NULL,
    fail integer DEFAULT 0 NOT NULL,
    pass integer DEFAULT 0 NOT NULL,
    result text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hib_results_result_check CHECK ((result = ANY (ARRAY['Pass'::text, 'Fail'::text])))
);


--
-- Name: key_dates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.key_dates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    modified_at timestamp with time zone,
    key_activity text,
    frequency text,
    certificate text,
    created_by uuid,
    modified_by uuid,
    due_date timestamp with time zone,
    updated_due_date timestamp with time zone
);


--
-- Name: TABLE key_dates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.key_dates IS 'Contains key dates for activities client must complete to stay cyber compliant';


--
-- Name: languages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.languages (
    code character varying(10) NOT NULL,
    name character varying(100) NOT NULL,
    display_name character varying(100),
    native_name character varying(100),
    preferred_engine character varying(50),
    fallback_engine character varying(50),
    is_active boolean DEFAULT true,
    is_beta boolean DEFAULT false,
    sort_order integer DEFAULT 0,
    flag_emoji character varying(10),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: template_variable_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.template_variable_translations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    variable_id uuid NOT NULL,
    language_code text DEFAULT 'en'::text NOT NULL,
    display_name text NOT NULL,
    default_value text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: template_variables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.template_variables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    category text NOT NULL,
    display_name text NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: COLUMN template_variables.key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.template_variables.key IS 'Variable key used in templates with double curly braces, e.g., {{lesson_title}}';


--
-- Name: learning_template_variables; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.learning_template_variables AS
 SELECT tv.key,
    tv.category,
    tv.display_name,
    tv.is_system,
    tv.is_active,
    tvt.default_value
   FROM (public.template_variables tv
     LEFT JOIN public.template_variable_translations tvt ON (((tv.id = tvt.variable_id) AND (tvt.language_code = 'en'::text))))
  WHERE (tv.category = 'Learning'::text)
  ORDER BY tv.key;


--
-- Name: VIEW learning_template_variables; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.learning_template_variables IS 'All learning-related template variables available for email templates and lesson notifications';


--
-- Name: learning_track_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.learning_track_assignments (
    assignment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    learning_track_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_by uuid,
    assigned_at timestamp with time zone DEFAULT now(),
    status text DEFAULT 'assigned'::text,
    notes text,
    reminder_sent boolean DEFAULT false,
    completion_required boolean DEFAULT true,
    due_date timestamp with time zone,
    CONSTRAINT learning_track_assignments_status_check CHECK ((status = ANY (ARRAY['assigned'::text, 'in_progress'::text, 'completed'::text, 'overdue'::text])))
);


--
-- Name: TABLE learning_track_assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.learning_track_assignments IS 'Individual user assignments for learning tracks';


--
-- Name: learning_track_department_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.learning_track_department_assignments (
    assignment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    learning_track_id uuid NOT NULL,
    department_id uuid NOT NULL,
    assigned_by uuid,
    assigned_at timestamp with time zone DEFAULT now(),
    due_date date,
    notes text
);


--
-- Name: TABLE learning_track_department_assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.learning_track_department_assignments IS 'Department-based assignments for learning tracks';


--
-- Name: learning_track_lessons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.learning_track_lessons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    learning_track_id uuid NOT NULL,
    lesson_id uuid NOT NULL,
    order_index integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: learning_track_role_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.learning_track_role_assignments (
    assignment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    learning_track_id uuid NOT NULL,
    role_id uuid NOT NULL,
    assigned_by uuid,
    assigned_at timestamp with time zone DEFAULT now(),
    due_date date,
    notes text
);


--
-- Name: TABLE learning_track_role_assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.learning_track_role_assignments IS 'Role-based assignments for learning tracks';


--
-- Name: learning_tracks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.learning_tracks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    description text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    schedule_type text DEFAULT 'flexible'::text NOT NULL,
    start_date date,
    end_date date,
    duration_weeks integer,
    lessons_per_week integer DEFAULT 1,
    allow_all_lessons_immediately boolean DEFAULT false,
    allow_parallel_tracks boolean DEFAULT false,
    schedule_days integer[],
    max_lessons_per_week integer,
    CONSTRAINT learning_tracks_schedule_type_check CHECK ((schedule_type = ANY (ARRAY['flexible'::text, 'fixed_dates'::text, 'duration_based'::text, 'weekly_schedule'::text])))
);


--
-- Name: COLUMN learning_tracks.allow_parallel_tracks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.learning_tracks.allow_parallel_tracks IS 'Whether this track can be run in parallel with other tracks (lessons can be started without completing previous ones)';


--
-- Name: COLUMN learning_tracks.schedule_days; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.learning_tracks.schedule_days IS 'Array of days of week (0=Sunday, 1=Monday, etc.) for weekly scheduling';


--
-- Name: COLUMN learning_tracks.max_lessons_per_week; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.learning_tracks.max_lessons_per_week IS 'Maximum lessons per week (null = unlimited) for weekly scheduling';


--
-- Name: lesson_answer_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_answer_translations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    answer_id text NOT NULL,
    language_code character varying(10) NOT NULL,
    text_translated text NOT NULL,
    explanation_translated text,
    engine_used character varying(50) DEFAULT 'google'::character varying NOT NULL,
    status character varying(20) DEFAULT 'completed'::character varying,
    character_count integer,
    translation_cost numeric(8,4) DEFAULT 0,
    quality_score numeric(3,2),
    is_outdated boolean DEFAULT false,
    needs_review boolean DEFAULT false,
    translated_by uuid,
    reviewed_by uuid,
    content_hash text,
    source_content_hash text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: lesson_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_answers (
    id text NOT NULL,
    node_id text NOT NULL,
    text text NOT NULL,
    next_node_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    score integer DEFAULT 0,
    is_correct boolean DEFAULT false,
    explanation text
);


--
-- Name: lesson_node_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_node_translations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    node_id text NOT NULL,
    language_code character varying(10),
    content_translated text NOT NULL,
    media_alt_translated text,
    engine_used character varying(50) NOT NULL,
    quality_score numeric(3,2),
    translation_cost numeric(8,4),
    character_count integer,
    status character varying(20) DEFAULT 'completed'::character varying,
    translated_by uuid,
    reviewed_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    source_content_hash text,
    is_outdated boolean DEFAULT false,
    needs_review boolean DEFAULT false,
    content_hash text
);


--
-- Name: lesson_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_nodes (
    id text NOT NULL,
    lesson_id uuid NOT NULL,
    type text NOT NULL,
    content text NOT NULL,
    media_type text,
    media_url text,
    media_alt text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    position_x integer,
    position_y integer,
    next_node_id text,
    allow_multiple boolean DEFAULT false,
    max_selections integer DEFAULT 1,
    min_selections integer DEFAULT 1,
    embedded_lesson_id uuid,
    content_hash text,
    CONSTRAINT lesson_nodes_type_check CHECK ((type = ANY (ARRAY['prompt'::text, 'question'::text, 'lesson'::text])))
);


--
-- Name: COLUMN lesson_nodes.position_x; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lesson_nodes.position_x IS 'X position of node in flowchart canvas (null = auto-calculate)';


--
-- Name: COLUMN lesson_nodes.position_y; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lesson_nodes.position_y IS 'Y position of node in flowchart canvas (null = auto-calculate)';


--
-- Name: COLUMN lesson_nodes.embedded_lesson_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lesson_nodes.embedded_lesson_id IS 'References a lesson that should be embedded when this node is reached';


--
-- Name: lesson_reminder_counts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_reminder_counts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    lesson_id uuid NOT NULL,
    learning_track_id uuid NOT NULL,
    reminder_count integer DEFAULT 0 NOT NULL,
    last_reminder_sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE lesson_reminder_counts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.lesson_reminder_counts IS 'Tracks how many reminders have been sent for each user/lesson combination';


--
-- Name: COLUMN lesson_reminder_counts.reminder_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lesson_reminder_counts.reminder_count IS 'Number of reminders sent (max 3 by default)';


--
-- Name: COLUMN lesson_reminder_counts.last_reminder_sent_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lesson_reminder_counts.last_reminder_sent_at IS 'When the last reminder was sent (used for 7-day cooldown)';


--
-- Name: lesson_reminder_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_reminder_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    lesson_id uuid NOT NULL,
    learning_track_id uuid,
    reminder_type text NOT NULL,
    available_date date NOT NULL,
    sent_at timestamp with time zone DEFAULT now(),
    email_notification_id uuid
);


--
-- Name: TABLE lesson_reminder_history; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.lesson_reminder_history IS 'History of sent lesson reminders to prevent duplicates. Links to email_notifications table';


--
-- Name: lesson_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_translations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    lesson_id uuid NOT NULL,
    language_code character varying(10),
    title_translated text NOT NULL,
    description_translated text,
    engine_used character varying(50) NOT NULL,
    quality_score numeric(3,2),
    translation_cost numeric(8,4),
    character_count integer,
    status character varying(20) DEFAULT 'completed'::character varying,
    translated_by uuid,
    reviewed_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    source_content_hash text,
    is_outdated boolean DEFAULT false,
    needs_review boolean DEFAULT false
);


--
-- Name: lessons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lessons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    description text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    start_node_id text,
    estimated_duration integer,
    updated_by uuid,
    lesson_type text DEFAULT 'lesson'::text,
    quiz_config jsonb,
    CONSTRAINT lessons_lesson_type_check CHECK ((lesson_type = ANY (ARRAY['lesson'::text, 'module'::text, 'quiz'::text])))
);


--
-- Name: COLUMN lessons.quiz_config; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.lessons.quiz_config IS 'JSON configuration for quiz-type lessons including passing percentage, retry policies, certificate settings, etc.';


--
-- Name: locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    building text,
    floor text,
    room text,
    status text DEFAULT 'Active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: notification_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_template_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    is_enabled boolean DEFAULT true,
    trigger_event text NOT NULL,
    trigger_conditions jsonb DEFAULT '{}'::jsonb,
    send_immediately boolean DEFAULT true,
    schedule_delay_minutes integer DEFAULT 0,
    send_at_time time without time zone,
    respect_quiet_hours boolean DEFAULT true,
    max_sends_per_user_per_day integer,
    cooldown_hours integer,
    override_priority text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    last_triggered_at timestamp with time zone,
    trigger_count integer DEFAULT 0
);


--
-- Name: TABLE notification_rules; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.notification_rules IS 'Configuration rules for when notifications are triggered and sent. References email_templates table.';


--
-- Name: COLUMN notification_rules.email_template_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notification_rules.email_template_id IS 'References existing email_templates table - the template to use for this notification';


--
-- Name: COLUMN notification_rules.trigger_conditions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notification_rules.trigger_conditions IS 'JSON object defining conditions that must be met for notification to send';


--
-- Name: org_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.org_profile (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_name text,
    organisation_name_short text,
    acra_uen_number text,
    charity_registration_number text,
    address text,
    telephone text,
    annual_turnover text,
    number_of_employees integer,
    number_of_executives integer,
    appointed_certification_body text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid
);


--
-- Name: org_sig_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.org_sig_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_type text NOT NULL,
    signatory_name text,
    signatory_title text,
    signatory_email text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid
);


--
-- Name: periodic_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.periodic_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    approved_at timestamp with time zone DEFAULT now() NOT NULL,
    approved_by uuid DEFAULT gen_random_uuid(),
    due_date timestamp with time zone,
    any_change boolean,
    summary_or_evidence text,
    approval_status public.approval_status_enum,
    activity text,
    submitted_by uuid,
    submitted_at timestamp with time zone
);


--
-- Name: TABLE periodic_reviews; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.periodic_reviews IS 'Logs of all periodic reviews';


--
-- Name: physical_location_access; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.physical_location_access (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name text NOT NULL,
    access_purpose text DEFAULT 'Primary Location'::text NOT NULL,
    date_access_created date NOT NULL,
    date_access_revoked date,
    status text DEFAULT 'Active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    location_id uuid NOT NULL,
    user_id uuid NOT NULL,
    CONSTRAINT physical_location_access_status_check CHECK ((status = ANY (ARRAY['Active'::text, 'Inactive'::text])))
);


--
-- Name: product_license_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_license_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    license_id uuid NOT NULL,
    access_level public.access_level_type DEFAULT 'user'::public.access_level_type NOT NULL
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    version integer
);


--
-- Name: TABLE products; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.products IS 'RAYN products that can be licensed out.';


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username text,
    full_name text,
    avatar_url text,
    bio text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    manager uuid,
    phone text,
    location text,
    start_date timestamp with time zone DEFAULT now(),
    employee_id text,
    last_login timestamp with time zone,
    password_last_changed timestamp with time zone DEFAULT now(),
    two_factor_enabled boolean DEFAULT false,
    status text DEFAULT 'Active'::text,
    cyber_learner boolean DEFAULT false,
    dpe_learner boolean DEFAULT false,
    learn_complete boolean DEFAULT false,
    dpe_complete boolean DEFAULT false,
    language text,
    enrolled_in_learn boolean DEFAULT false,
    location_id uuid,
    first_name text,
    last_name text,
    activated_at timestamp without time zone,
    CONSTRAINT profiles_status_check CHECK ((status = ANY (ARRAY['Pending'::text, 'Active'::text, 'Inactive'::text, 'OnLeave'::text])))
);


--
-- Name: COLUMN profiles.enrolled_in_learn; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.enrolled_in_learn IS 'Indicates person has enrolled in Learn';


--
-- Name: quiz_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quiz_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    lesson_id uuid NOT NULL,
    attempt_number integer DEFAULT 1 NOT NULL,
    total_questions integer NOT NULL,
    correct_answers integer NOT NULL,
    percentage_score numeric NOT NULL,
    passed boolean NOT NULL,
    completed_at timestamp with time zone DEFAULT now(),
    answers_data jsonb DEFAULT '[]'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    role_id uuid DEFAULT gen_random_uuid() NOT NULL,
    department_id uuid,
    name text NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: software_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_inventory (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    software_name text NOT NULL,
    software_publisher text,
    software_version text,
    business_purpose text,
    department text,
    asset_classification text,
    approval_authorized_date date,
    end_of_support_date date,
    status text DEFAULT 'Active'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    license_start_date timestamp with time zone,
    term smallint
);


--
-- Name: COLUMN software_inventory.term; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.software_inventory.term IS 'license term in months';


--
-- Name: template_performance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.template_performance AS
 SELECT et.id,
    et.name,
    et.type,
    COALESCE(et.use_count, 0) AS use_count,
    et.last_used_at,
    count(nh.id) AS total_sends,
    count(
        CASE
            WHEN (nh.status = 'sent'::text) THEN 1
            ELSE NULL::integer
        END) AS successful_sends,
    count(
        CASE
            WHEN (nh.status = 'failed'::text) THEN 1
            ELSE NULL::integer
        END) AS failed_sends,
    count(
        CASE
            WHEN (nh.status = 'skipped'::text) THEN 1
            ELSE NULL::integer
        END) AS skipped_sends,
    round(((100.0 * (count(
        CASE
            WHEN (nh.status = 'sent'::text) THEN 1
            ELSE NULL::integer
        END))::numeric) / (NULLIF(count(nh.id), 0))::numeric), 2) AS success_rate
   FROM (public.email_templates et
     LEFT JOIN public.notification_history nh ON ((nh.email_template_id = et.id)))
  GROUP BY et.id, et.name, et.type, et.use_count, et.last_used_at
  ORDER BY (count(nh.id)) DESC;


--
-- Name: template_variables_by_category; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.template_variables_by_category AS
 SELECT category,
    count(*) AS variable_count,
    string_agg(key, ', '::text ORDER BY key) AS variable_keys
   FROM public.template_variables tv
  WHERE (is_active = true)
  GROUP BY category
  ORDER BY category;


--
-- Name: VIEW template_variables_by_category; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.template_variables_by_category IS 'Summary of all template variables grouped by category for easy reference';


--
-- Name: translation_change_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_change_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    table_name character varying(50) NOT NULL,
    record_id text NOT NULL,
    lesson_id uuid,
    field_name character varying(50) NOT NULL,
    old_value text,
    new_value text,
    old_hash text,
    new_hash text,
    change_type character varying(20) NOT NULL,
    change_magnitude character varying(10),
    character_difference integer,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now(),
    affected_translations integer DEFAULT 0,
    estimated_retranslation_cost numeric(8,4)
);


--
-- Name: translation_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    lesson_id uuid NOT NULL,
    target_language character varying(10),
    status character varying(20) DEFAULT 'pending'::character varying,
    total_items integer NOT NULL,
    completed_items integer DEFAULT 0,
    failed_items integer DEFAULT 0,
    total_cost numeric(8,4) DEFAULT 0,
    total_characters integer DEFAULT 0,
    estimated_duration integer,
    actual_duration integer,
    requested_by uuid,
    priority integer DEFAULT 5,
    error_message text,
    retry_count integer DEFAULT 0,
    max_retries integer DEFAULT 3,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone
);


--
-- Name: user_answer_responses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_answer_responses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    lesson_id uuid,
    node_id text NOT NULL,
    answer_ids text[] NOT NULL,
    scores integer[] NOT NULL,
    total_score integer NOT NULL,
    response_time_ms integer,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_behavior_analytics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_behavior_analytics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    lesson_id uuid,
    session_id text NOT NULL,
    total_time_spent integer NOT NULL,
    nodes_visited text[] NOT NULL,
    completion_path text[] NOT NULL,
    retry_count integer DEFAULT 0,
    completed_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_deletion_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_deletion_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    deleted_user_name text NOT NULL,
    deleted_user_email text NOT NULL,
    deleted_user_id uuid NOT NULL,
    deleted_by uuid NOT NULL,
    deleted_at timestamp with time zone DEFAULT now() NOT NULL,
    deletion_reason text,
    approved_by uuid,
    approved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_departments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    department_id uuid NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_by uuid,
    is_primary boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    pairing_id uuid
);


--
-- Name: TABLE user_departments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_departments IS 'Department assignments for users. RLS policies ensure users can only see their own assignments, managers see their department members, and admins see all.';


--
-- Name: user_learning_track_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_learning_track_progress (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    learning_track_id uuid NOT NULL,
    enrolled_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    current_lesson_order integer DEFAULT 0,
    progress_percentage integer DEFAULT 0,
    next_available_date date DEFAULT CURRENT_DATE
);


--
-- Name: COLUMN user_learning_track_progress.progress_percentage; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_learning_track_progress.progress_percentage IS 'Percentage completion of the track';


--
-- Name: COLUMN user_learning_track_progress.next_available_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_learning_track_progress.next_available_date IS 'Date when next lesson becomes available';


--
-- Name: user_lesson_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_lesson_progress (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    lesson_id uuid NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    current_node_id text,
    completed_nodes text[],
    last_accessed timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_phishing_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_phishing_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_name text,
    type text,
    resource text,
    user_id uuid NOT NULL,
    phish_date date NOT NULL,
    ip_address text
);


--
-- Name: user_profile_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profile_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_by uuid,
    is_primary boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    pairing_id uuid,
    role_id uuid NOT NULL
);


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    role public.app_role DEFAULT 'user'::public.app_role NOT NULL
);


--
-- Name: account_inventory account_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_inventory
    ADD CONSTRAINT account_inventory_pkey PRIMARY KEY (id);


--
-- Name: breach_management_team breach_management_team_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breach_management_team
    ADD CONSTRAINT breach_management_team_pkey PRIMARY KEY (id);


--
-- Name: breach_team_members breach_team_members_breach_team_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breach_team_members
    ADD CONSTRAINT breach_team_members_breach_team_id_user_id_key UNIQUE (breach_team_id, user_id);


--
-- Name: breach_team_members breach_team_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breach_team_members
    ADD CONSTRAINT breach_team_members_pkey PRIMARY KEY (id);


--
-- Name: certificates certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_pkey PRIMARY KEY (id);


--
-- Name: csba_answers csba_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csba_answers
    ADD CONSTRAINT csba_answers_pkey PRIMARY KEY (id);


--
-- Name: csba_master csba_master_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csba_master
    ADD CONSTRAINT csba_master_pkey PRIMARY KEY (id, question_id);


--
-- Name: csba_master csba_master_question_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csba_master
    ADD CONSTRAINT csba_master_question_id_key UNIQUE (question_id);


--
-- Name: customer_product_licenses customer_product_licenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_product_licenses
    ADD CONSTRAINT customer_product_licenses_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: departments departments_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_name_key UNIQUE (name);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: document_assignments document_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_assignments
    ADD CONSTRAINT document_assignments_pkey PRIMARY KEY (assignment_id);


--
-- Name: document_assignments document_assignments_user_id_document_id_document_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_assignments
    ADD CONSTRAINT document_assignments_user_id_document_id_document_version_key UNIQUE (user_id, document_id, document_version);


--
-- Name: document_departments document_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_departments
    ADD CONSTRAINT document_departments_pkey PRIMARY KEY (document_id, department_id);


--
-- Name: document_roles document_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_roles
    ADD CONSTRAINT document_roles_pkey PRIMARY KEY (document_id, role_id);


--
-- Name: document_users document_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_users
    ADD CONSTRAINT document_users_pkey PRIMARY KEY (document_id, user_id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (document_id);


--
-- Name: email_layouts email_layouts_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layouts
    ADD CONSTRAINT email_layouts_name_key UNIQUE (name);


--
-- Name: email_layouts email_layouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layouts
    ADD CONSTRAINT email_layouts_pkey PRIMARY KEY (id);


--
-- Name: email_notifications email_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_notifications
    ADD CONSTRAINT email_notifications_pkey PRIMARY KEY (id);


--
-- Name: email_preferences email_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_preferences
    ADD CONSTRAINT email_preferences_pkey PRIMARY KEY (id);


--
-- Name: email_templates email_templates_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_name_key UNIQUE (name);


--
-- Name: email_templates email_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_pkey PRIMARY KEY (id);


--
-- Name: hardware_inventory hardware_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_inventory
    ADD CONSTRAINT hardware_inventory_pkey PRIMARY KEY (id);


--
-- Name: hardware_inventory hardware_inventory_serial_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware_inventory
    ADD CONSTRAINT hardware_inventory_serial_number_key UNIQUE (serial_number);


--
-- Name: hardware hardware_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware
    ADD CONSTRAINT hardware_pkey PRIMARY KEY (id);


--
-- Name: hardware hardware_serial_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware
    ADD CONSTRAINT hardware_serial_number_key UNIQUE (serial_number);


--
-- Name: hib_checklist hib_checklist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hib_checklist
    ADD CONSTRAINT hib_checklist_pkey PRIMARY KEY (id);


--
-- Name: hib_results hib_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hib_results
    ADD CONSTRAINT hib_results_pkey PRIMARY KEY (id);


--
-- Name: key_dates key_dates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.key_dates
    ADD CONSTRAINT key_dates_pkey PRIMARY KEY (id);


--
-- Name: languages languages_display_name_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.languages
    ADD CONSTRAINT languages_display_name_unique UNIQUE (display_name);


--
-- Name: languages languages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.languages
    ADD CONSTRAINT languages_pkey PRIMARY KEY (code);


--
-- Name: learning_track_assignments learning_track_assignments_learning_track_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_assignments
    ADD CONSTRAINT learning_track_assignments_learning_track_id_user_id_key UNIQUE (learning_track_id, user_id);


--
-- Name: learning_track_assignments learning_track_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_assignments
    ADD CONSTRAINT learning_track_assignments_pkey PRIMARY KEY (assignment_id);


--
-- Name: learning_track_department_assignments learning_track_department_ass_learning_track_id_department__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_department_assignments
    ADD CONSTRAINT learning_track_department_ass_learning_track_id_department__key UNIQUE (learning_track_id, department_id);


--
-- Name: learning_track_department_assignments learning_track_department_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_department_assignments
    ADD CONSTRAINT learning_track_department_assignments_pkey PRIMARY KEY (assignment_id);


--
-- Name: learning_track_lessons learning_track_lessons_learning_track_id_lesson_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_lessons
    ADD CONSTRAINT learning_track_lessons_learning_track_id_lesson_id_key UNIQUE (learning_track_id, lesson_id);


--
-- Name: learning_track_lessons learning_track_lessons_learning_track_id_order_index_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_lessons
    ADD CONSTRAINT learning_track_lessons_learning_track_id_order_index_key UNIQUE (learning_track_id, order_index);


--
-- Name: learning_track_lessons learning_track_lessons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_lessons
    ADD CONSTRAINT learning_track_lessons_pkey PRIMARY KEY (id);


--
-- Name: learning_track_role_assignments learning_track_role_assignments_learning_track_id_role_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_role_assignments
    ADD CONSTRAINT learning_track_role_assignments_learning_track_id_role_id_key UNIQUE (learning_track_id, role_id);


--
-- Name: learning_track_role_assignments learning_track_role_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_role_assignments
    ADD CONSTRAINT learning_track_role_assignments_pkey PRIMARY KEY (assignment_id);


--
-- Name: learning_tracks learning_tracks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_tracks
    ADD CONSTRAINT learning_tracks_pkey PRIMARY KEY (id);


--
-- Name: lesson_answer_translations lesson_answer_translations_answer_id_language_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answer_translations
    ADD CONSTRAINT lesson_answer_translations_answer_id_language_code_key UNIQUE (answer_id, language_code);


--
-- Name: lesson_answer_translations lesson_answer_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answer_translations
    ADD CONSTRAINT lesson_answer_translations_pkey PRIMARY KEY (id);


--
-- Name: lesson_answers lesson_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answers
    ADD CONSTRAINT lesson_answers_pkey PRIMARY KEY (id);


--
-- Name: lesson_node_translations lesson_node_translations_node_id_language_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_node_translations
    ADD CONSTRAINT lesson_node_translations_node_id_language_code_key UNIQUE (node_id, language_code);


--
-- Name: lesson_node_translations lesson_node_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_node_translations
    ADD CONSTRAINT lesson_node_translations_pkey PRIMARY KEY (id);


--
-- Name: lesson_nodes lesson_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_nodes
    ADD CONSTRAINT lesson_nodes_pkey PRIMARY KEY (id);


--
-- Name: lesson_reminder_counts lesson_reminder_counts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_counts
    ADD CONSTRAINT lesson_reminder_counts_pkey PRIMARY KEY (id);


--
-- Name: lesson_reminder_counts lesson_reminder_counts_user_id_lesson_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_counts
    ADD CONSTRAINT lesson_reminder_counts_user_id_lesson_id_key UNIQUE (user_id, lesson_id);


--
-- Name: lesson_reminder_history lesson_reminder_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_history
    ADD CONSTRAINT lesson_reminder_history_pkey PRIMARY KEY (id);


--
-- Name: lesson_translations lesson_translations_lesson_id_language_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_translations
    ADD CONSTRAINT lesson_translations_lesson_id_language_code_key UNIQUE (lesson_id, language_code);


--
-- Name: lesson_translations lesson_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_translations
    ADD CONSTRAINT lesson_translations_pkey PRIMARY KEY (id);


--
-- Name: lessons lessons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_pkey PRIMARY KEY (id);


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: notification_history notification_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_history
    ADD CONSTRAINT notification_history_pkey PRIMARY KEY (id);


--
-- Name: notification_rules notification_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_pkey PRIMARY KEY (id);


--
-- Name: org_profile org_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_profile
    ADD CONSTRAINT org_profile_pkey PRIMARY KEY (id);


--
-- Name: org_sig_roles org_sig_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_sig_roles
    ADD CONSTRAINT org_sig_roles_pkey PRIMARY KEY (id);


--
-- Name: org_sig_roles org_sig_roles_role_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_sig_roles
    ADD CONSTRAINT org_sig_roles_role_type_key UNIQUE (role_type);


--
-- Name: periodic_reviews periodic_reviews_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.periodic_reviews
    ADD CONSTRAINT periodic_reviews_log_pkey PRIMARY KEY (id);


--
-- Name: physical_location_access physical_location_access_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physical_location_access
    ADD CONSTRAINT physical_location_access_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_username_key UNIQUE (username);


--
-- Name: quiz_attempts quiz_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quiz_attempts
    ADD CONSTRAINT quiz_attempts_pkey PRIMARY KEY (id);


--
-- Name: quiz_attempts quiz_attempts_user_id_lesson_id_attempt_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quiz_attempts
    ADD CONSTRAINT quiz_attempts_user_id_lesson_id_attempt_number_key UNIQUE (user_id, lesson_id, attempt_number);


--
-- Name: roles roles_department_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_department_id_name_key UNIQUE (department_id, name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- Name: software_inventory software_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_inventory
    ADD CONSTRAINT software_inventory_pkey PRIMARY KEY (id);


--
-- Name: template_variable_translations template_variable_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_variable_translations
    ADD CONSTRAINT template_variable_translations_pkey PRIMARY KEY (id);


--
-- Name: template_variable_translations template_variable_translations_variable_id_language_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_variable_translations
    ADD CONSTRAINT template_variable_translations_variable_id_language_code_key UNIQUE (variable_id, language_code);


--
-- Name: template_variables template_variables_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_variables
    ADD CONSTRAINT template_variables_key_key UNIQUE (key);


--
-- Name: template_variables template_variables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_variables
    ADD CONSTRAINT template_variables_pkey PRIMARY KEY (id);


--
-- Name: translation_change_log translation_change_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_change_log
    ADD CONSTRAINT translation_change_log_pkey PRIMARY KEY (id);


--
-- Name: translation_jobs translation_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_jobs
    ADD CONSTRAINT translation_jobs_pkey PRIMARY KEY (id);


--
-- Name: user_departments unique_user_department; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT unique_user_department UNIQUE (user_id, department_id);


--
-- Name: user_profile_roles unique_user_role; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile_roles
    ADD CONSTRAINT unique_user_role UNIQUE (user_id, role_id);


--
-- Name: user_answer_responses user_answer_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_answer_responses
    ADD CONSTRAINT user_answer_responses_pkey PRIMARY KEY (id);


--
-- Name: user_behavior_analytics user_behavior_analytics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_behavior_analytics
    ADD CONSTRAINT user_behavior_analytics_pkey PRIMARY KEY (id);


--
-- Name: user_deletion_audit user_deletion_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_audit
    ADD CONSTRAINT user_deletion_audit_pkey PRIMARY KEY (id);


--
-- Name: user_departments user_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT user_departments_pkey PRIMARY KEY (id);


--
-- Name: user_departments user_departments_user_id_department_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT user_departments_user_id_department_id_key UNIQUE (user_id, department_id);


--
-- Name: user_learning_track_progress user_learning_track_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_track_progress
    ADD CONSTRAINT user_learning_track_progress_pkey PRIMARY KEY (id);


--
-- Name: user_learning_track_progress user_learning_track_progress_user_id_learning_track_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_track_progress
    ADD CONSTRAINT user_learning_track_progress_user_id_learning_track_id_key UNIQUE (user_id, learning_track_id);


--
-- Name: user_lesson_progress user_lesson_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_lesson_progress
    ADD CONSTRAINT user_lesson_progress_pkey PRIMARY KEY (id);


--
-- Name: user_lesson_progress user_lesson_progress_user_id_lesson_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_lesson_progress
    ADD CONSTRAINT user_lesson_progress_user_id_lesson_id_key UNIQUE (user_id, lesson_id);


--
-- Name: user_phishing_scores user_phishing_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_phishing_scores
    ADD CONSTRAINT user_phishing_scores_pkey PRIMARY KEY (id);


--
-- Name: product_license_assignments user_product_licenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_license_assignments
    ADD CONSTRAINT user_product_licenses_pkey PRIMARY KEY (id);


--
-- Name: user_profile_roles user_profile_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile_roles
    ADD CONSTRAINT user_profile_roles_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_key UNIQUE (user_id);


--
-- Name: idx_account_inventory_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_inventory_status ON public.account_inventory USING btree (status);


--
-- Name: idx_account_inventory_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_inventory_user_id ON public.account_inventory USING btree (user_id);


--
-- Name: idx_account_inventory_username; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_inventory_username ON public.account_inventory USING btree (username_email);


--
-- Name: idx_breach_management_team_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_breach_management_team_member ON public.breach_management_team USING btree (member);


--
-- Name: idx_email_layouts_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_layouts_active ON public.email_layouts USING btree (is_active);


--
-- Name: idx_email_layouts_default; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_layouts_default ON public.email_layouts USING btree (is_default);


--
-- Name: idx_email_notifications_scheduled_for; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_notifications_scheduled_for ON public.email_notifications USING btree (scheduled_for);


--
-- Name: idx_email_notifications_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_notifications_status ON public.email_notifications USING btree (status);


--
-- Name: idx_email_notifications_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_notifications_type ON public.email_notifications USING btree (type);


--
-- Name: idx_email_notifications_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_notifications_user_id ON public.email_notifications USING btree (user_id);


--
-- Name: idx_email_templates_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_templates_active ON public.email_templates USING btree (is_active);


--
-- Name: idx_email_templates_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_templates_category ON public.email_templates USING btree (category);


--
-- Name: idx_email_templates_layout; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_templates_layout ON public.email_templates USING btree (layout_id);


--
-- Name: idx_email_templates_system; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_templates_system ON public.email_templates USING btree (is_system);


--
-- Name: idx_email_templates_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_templates_type ON public.email_templates USING btree (type);


--
-- Name: idx_hardware_inventory_serial; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hardware_inventory_serial ON public.hardware_inventory USING btree (serial_number);


--
-- Name: idx_hardware_inventory_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hardware_inventory_status ON public.hardware_inventory USING btree (status);


--
-- Name: idx_hib_results_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hib_results_user_id ON public.hib_results USING btree (user_id);


--
-- Name: idx_history_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_created ON public.notification_history USING btree (created_at DESC);


--
-- Name: idx_history_email_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_email_template ON public.notification_history USING btree (email_template_id);


--
-- Name: idx_history_rule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_rule ON public.notification_history USING btree (rule_id);


--
-- Name: idx_history_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_sent_at ON public.notification_history USING btree (sent_at DESC);


--
-- Name: idx_history_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_status ON public.notification_history USING btree (status);


--
-- Name: idx_history_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_status_created ON public.notification_history USING btree (status, created_at DESC);


--
-- Name: idx_history_trigger_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_trigger_event ON public.notification_history USING btree (trigger_event);


--
-- Name: idx_history_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_user ON public.notification_history USING btree (user_id);


--
-- Name: idx_history_user_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_history_user_event ON public.notification_history USING btree (user_id, trigger_event);


--
-- Name: idx_learning_track_assignments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_assignments_status ON public.learning_track_assignments USING btree (status);


--
-- Name: idx_learning_track_assignments_track_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_assignments_track_id ON public.learning_track_assignments USING btree (learning_track_id);


--
-- Name: idx_learning_track_assignments_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_assignments_user_id ON public.learning_track_assignments USING btree (user_id);


--
-- Name: idx_learning_track_dept_assignments_dept_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_dept_assignments_dept_id ON public.learning_track_department_assignments USING btree (department_id);


--
-- Name: idx_learning_track_dept_assignments_track_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_dept_assignments_track_id ON public.learning_track_department_assignments USING btree (learning_track_id);


--
-- Name: idx_learning_track_role_assignments_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_role_assignments_role_id ON public.learning_track_role_assignments USING btree (role_id);


--
-- Name: idx_learning_track_role_assignments_track_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_learning_track_role_assignments_track_id ON public.learning_track_role_assignments USING btree (learning_track_id);


--
-- Name: idx_lesson_answer_translations_answer_language; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_answer_translations_answer_language ON public.lesson_answer_translations USING btree (answer_id, language_code);


--
-- Name: idx_lesson_node_translations_language; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_node_translations_language ON public.lesson_node_translations USING btree (language_code);


--
-- Name: idx_lesson_node_translations_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_node_translations_lookup ON public.lesson_node_translations USING btree (node_id, language_code);


--
-- Name: idx_lesson_node_translations_node; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_node_translations_node ON public.lesson_node_translations USING btree (node_id);


--
-- Name: idx_lesson_reminder_counts_last_sent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_counts_last_sent ON public.lesson_reminder_counts USING btree (last_reminder_sent_at);


--
-- Name: idx_lesson_reminder_counts_track; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_counts_track ON public.lesson_reminder_counts USING btree (learning_track_id);


--
-- Name: idx_lesson_reminder_counts_user_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_counts_user_lesson ON public.lesson_reminder_counts USING btree (user_id, lesson_id);


--
-- Name: idx_lesson_reminder_history_composite; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_history_composite ON public.lesson_reminder_history USING btree (user_id, lesson_id, available_date);


--
-- Name: idx_lesson_reminder_history_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_history_lesson ON public.lesson_reminder_history USING btree (lesson_id);


--
-- Name: idx_lesson_reminder_history_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_history_sent_at ON public.lesson_reminder_history USING btree (sent_at);


--
-- Name: idx_lesson_reminder_history_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_reminder_history_user ON public.lesson_reminder_history USING btree (user_id);


--
-- Name: idx_lesson_reminder_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_lesson_reminder_unique ON public.lesson_reminder_history USING btree (user_id, lesson_id, reminder_type, available_date);


--
-- Name: idx_lesson_translations_language; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_translations_language ON public.lesson_translations USING btree (language_code);


--
-- Name: idx_lesson_translations_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_translations_lesson ON public.lesson_translations USING btree (lesson_id);


--
-- Name: idx_lesson_translations_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lesson_translations_lookup ON public.lesson_translations USING btree (lesson_id, language_code);


--
-- Name: idx_lessons_lesson_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lessons_lesson_type ON public.lessons USING btree (lesson_type) WHERE (lesson_type IS NOT NULL);


--
-- Name: idx_lessons_quiz_config; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lessons_quiz_config ON public.lessons USING gin (quiz_config) WHERE (lesson_type = 'quiz'::text);


--
-- Name: idx_physical_location_access_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_physical_location_access_user_id ON public.physical_location_access USING btree (user_id);


--
-- Name: idx_profiles_location_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_location_id ON public.profiles USING btree (location_id);


--
-- Name: idx_quiz_attempts_completed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quiz_attempts_completed_at ON public.quiz_attempts USING btree (completed_at DESC);


--
-- Name: idx_quiz_attempts_user_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quiz_attempts_user_lesson ON public.quiz_attempts USING btree (user_id, lesson_id);


--
-- Name: idx_rules_email_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rules_email_template ON public.notification_rules USING btree (email_template_id);


--
-- Name: idx_rules_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rules_enabled ON public.notification_rules USING btree (is_enabled);


--
-- Name: idx_rules_last_triggered; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rules_last_triggered ON public.notification_rules USING btree (last_triggered_at);


--
-- Name: idx_rules_trigger_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rules_trigger_event ON public.notification_rules USING btree (trigger_event);


--
-- Name: idx_software_inventory_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_software_inventory_name ON public.software_inventory USING btree (software_name);


--
-- Name: idx_software_inventory_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_software_inventory_status ON public.software_inventory USING btree (status);


--
-- Name: idx_translation_change_log_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_change_log_date ON public.translation_change_log USING btree (updated_at);


--
-- Name: idx_translation_change_log_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_change_log_lesson ON public.translation_change_log USING btree (lesson_id);


--
-- Name: idx_translation_change_log_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_change_log_type ON public.translation_change_log USING btree (change_type);


--
-- Name: idx_translation_jobs_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_jobs_lesson ON public.translation_jobs USING btree (lesson_id);


--
-- Name: idx_translation_jobs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_jobs_status ON public.translation_jobs USING btree (status);


--
-- Name: idx_translation_jobs_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_jobs_user ON public.translation_jobs USING btree (requested_by);


--
-- Name: idx_user_answer_responses_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_answer_responses_created_at ON public.user_answer_responses USING btree (created_at);


--
-- Name: idx_user_answer_responses_user_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_answer_responses_user_lesson ON public.user_answer_responses USING btree (user_id, lesson_id);


--
-- Name: idx_user_behavior_analytics_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_behavior_analytics_session ON public.user_behavior_analytics USING btree (session_id);


--
-- Name: idx_user_behavior_analytics_user_lesson; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_behavior_analytics_user_lesson ON public.user_behavior_analytics USING btree (user_id, lesson_id);


--
-- Name: idx_user_departments_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_departments_department_id ON public.user_departments USING btree (department_id);


--
-- Name: idx_user_departments_pairing_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_departments_pairing_id ON public.user_departments USING btree (pairing_id) WHERE (pairing_id IS NOT NULL);


--
-- Name: idx_user_departments_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_departments_user_id ON public.user_departments USING btree (user_id);


--
-- Name: idx_user_profile_roles_pairing_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_profile_roles_pairing_id ON public.user_profile_roles USING btree (pairing_id) WHERE (pairing_id IS NOT NULL);


--
-- Name: idx_user_profile_roles_primary; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_profile_roles_primary ON public.user_profile_roles USING btree (user_id, is_primary) WHERE (is_primary = true);


--
-- Name: idx_user_profile_roles_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_profile_roles_role_id ON public.user_profile_roles USING btree (role_id);


--
-- Name: idx_user_profile_roles_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_profile_roles_user_id ON public.user_profile_roles USING btree (user_id);


--
-- Name: breach_team_members add_breach_team_assignments_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER add_breach_team_assignments_trigger AFTER INSERT ON public.breach_team_members FOR EACH ROW EXECUTE FUNCTION public.add_breach_team_assignments();


--
-- Name: profiles after_profile_activation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER after_profile_activation AFTER UPDATE ON public.profiles FOR EACH ROW WHEN (((new.status = 'Active'::text) AND (old.status <> 'Active'::text))) EXECUTE FUNCTION public.handle_profile_activation();


--
-- Name: profiles before_profile_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER before_profile_delete BEFORE DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.handle_profile_deletion();


--
-- Name: breach_team_members cleanup_breach_team_assignments_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cleanup_breach_team_assignments_trigger AFTER DELETE ON public.breach_team_members FOR EACH ROW EXECUTE FUNCTION public.cleanup_breach_team_assignments();


--
-- Name: email_layouts email_layout_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER email_layout_updated_at BEFORE UPDATE ON public.email_layouts FOR EACH ROW EXECUTE FUNCTION public.update_email_layout_updated_at();


--
-- Name: product_license_assignments enforce_license_seat_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_license_seat_count BEFORE INSERT OR UPDATE ON public.product_license_assignments FOR EACH ROW EXECUTE FUNCTION public.prevent_license_over_assignment();


--
-- Name: document_departments generate_assignments_on_department_target; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER generate_assignments_on_department_target AFTER INSERT ON public.document_departments FOR EACH ROW EXECUTE FUNCTION public.trigger_generate_assignments();


--
-- Name: document_roles generate_assignments_on_role_target; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER generate_assignments_on_role_target AFTER INSERT ON public.document_roles FOR EACH ROW EXECUTE FUNCTION public.trigger_generate_assignments();


--
-- Name: document_users generate_assignments_on_user_target; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER generate_assignments_on_user_target AFTER INSERT ON public.document_users FOR EACH ROW EXECUTE FUNCTION public.trigger_generate_assignments();


--
-- Name: lessons mark_lesson_translations_outdated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER mark_lesson_translations_outdated AFTER UPDATE ON public.lessons FOR EACH ROW EXECUTE FUNCTION public.mark_translations_outdated();


--
-- Name: lesson_nodes mark_node_translations_outdated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER mark_node_translations_outdated AFTER UPDATE ON public.lesson_nodes FOR EACH ROW EXECUTE FUNCTION public.mark_node_translations_outdated();


--
-- Name: notification_rules notification_rule_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER notification_rule_updated_at BEFORE UPDATE ON public.notification_rules FOR EACH ROW EXECUTE FUNCTION public.update_notification_rule_updated_at();


--
-- Name: breach_management_team protect_system_breach_roles_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_system_breach_roles_trigger BEFORE DELETE OR UPDATE ON public.breach_management_team FOR EACH ROW EXECUTE FUNCTION public.protect_system_breach_roles();


--
-- Name: lessons track_lesson_changes_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER track_lesson_changes_trigger BEFORE UPDATE ON public.lessons FOR EACH ROW EXECUTE FUNCTION public.track_lesson_changes();


--
-- Name: lesson_nodes track_lesson_node_changes_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER track_lesson_node_changes_trigger BEFORE UPDATE ON public.lesson_nodes FOR EACH ROW EXECUTE FUNCTION public.track_lesson_node_changes();


--
-- Name: learning_track_department_assignments trigger_department_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_department_assignment AFTER INSERT ON public.learning_track_department_assignments FOR EACH ROW EXECUTE FUNCTION public.handle_department_assignment();


--
-- Name: user_departments trigger_generate_assignments_on_user_department; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_generate_assignments_on_user_department AFTER INSERT ON public.user_departments FOR EACH ROW EXECUTE FUNCTION public.generate_assignments_for_user_department();


--
-- Name: user_profile_roles trigger_generate_assignments_on_user_role; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_generate_assignments_on_user_role AFTER INSERT ON public.user_profile_roles FOR EACH ROW EXECUTE FUNCTION public.generate_assignments_for_user_role();


--
-- Name: learning_track_role_assignments trigger_role_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_role_assignment AFTER INSERT ON public.learning_track_role_assignments FOR EACH ROW EXECUTE FUNCTION public.handle_role_assignment();


--
-- Name: breach_management_team update_breach_management_team_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_breach_management_team_updated_at BEFORE UPDATE ON public.breach_management_team FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: breach_team_members update_breach_team_members_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_breach_team_members_updated_at BEFORE UPDATE ON public.breach_team_members FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: departments update_departments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_departments_updated_at BEFORE UPDATE ON public.departments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: documents update_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_documents_updated_at BEFORE UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: email_templates update_email_templates_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_email_templates_updated_at BEFORE UPDATE ON public.email_templates FOR EACH ROW EXECUTE FUNCTION public.update_email_templates_updated_at();


--
-- Name: hib_checklist update_hib_checklist_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_hib_checklist_updated_at BEFORE UPDATE ON public.hib_checklist FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: hib_results update_hib_results_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_hib_results_updated_at BEFORE UPDATE ON public.hib_results FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: learning_tracks update_learning_tracks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_learning_tracks_updated_at BEFORE UPDATE ON public.learning_tracks FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lesson_node_translations update_lesson_node_translations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_lesson_node_translations_updated_at BEFORE UPDATE ON public.lesson_node_translations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lesson_nodes update_lesson_nodes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_lesson_nodes_updated_at BEFORE UPDATE ON public.lesson_nodes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lesson_translations update_lesson_translations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_lesson_translations_updated_at BEFORE UPDATE ON public.lesson_translations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lessons update_lessons_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_lessons_updated_at BEFORE UPDATE ON public.lessons FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lesson_nodes update_node_content_hash_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_node_content_hash_trigger BEFORE INSERT OR UPDATE ON public.lesson_nodes FOR EACH ROW EXECUTE FUNCTION public.update_node_content_hash();


--
-- Name: org_profile update_org_profile_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_org_profile_updated_at BEFORE UPDATE ON public.org_profile FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: org_sig_roles update_org_sig_roles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_org_sig_roles_updated_at BEFORE UPDATE ON public.org_sig_roles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: roles update_roles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_roles_updated_at BEFORE UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: template_variable_translations update_template_variable_translations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_template_variable_translations_updated_at BEFORE UPDATE ON public.template_variable_translations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: template_variables update_template_variables_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_template_variables_updated_at BEFORE UPDATE ON public.template_variables FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: lesson_node_translations update_translation_content_hash_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_translation_content_hash_trigger BEFORE INSERT OR UPDATE ON public.lesson_node_translations FOR EACH ROW EXECUTE FUNCTION public.update_translation_content_hash();


--
-- Name: user_departments update_user_departments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_departments_updated_at BEFORE UPDATE ON public.user_departments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: user_profile_roles update_user_profile_roles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_profile_roles_updated_at BEFORE UPDATE ON public.user_profile_roles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: account_inventory account_inventory_authorized_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_inventory
    ADD CONSTRAINT account_inventory_authorized_by_fkey FOREIGN KEY (authorized_by) REFERENCES public.profiles(id);


--
-- Name: breach_management_team breach_management_team_member_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breach_management_team
    ADD CONSTRAINT breach_management_team_member_fkey FOREIGN KEY (member) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: breach_team_members breach_team_members_breach_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breach_team_members
    ADD CONSTRAINT breach_team_members_breach_team_id_fkey FOREIGN KEY (breach_team_id) REFERENCES public.breach_management_team(id) ON DELETE CASCADE;


--
-- Name: certificates certificates_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: csba_answers csba_answers_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csba_answers
    ADD CONSTRAINT csba_answers_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.csba_master(question_id);


--
-- Name: csba_answers csba_answers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csba_answers
    ADD CONSTRAINT csba_answers_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: customer_product_licenses customer_product_licenses_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_product_licenses
    ADD CONSTRAINT customer_product_licenses_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: customer_product_licenses customer_product_licenses_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_product_licenses
    ADD CONSTRAINT customer_product_licenses_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: departments departments_manager_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.profiles(id);


--
-- Name: document_assignments document_assignments_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_assignments
    ADD CONSTRAINT document_assignments_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(document_id) ON DELETE CASCADE;


--
-- Name: document_departments document_departments_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_departments
    ADD CONSTRAINT document_departments_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE CASCADE;


--
-- Name: document_departments document_departments_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_departments
    ADD CONSTRAINT document_departments_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(document_id) ON DELETE CASCADE;


--
-- Name: document_roles document_roles_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_roles
    ADD CONSTRAINT document_roles_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(document_id) ON DELETE CASCADE;


--
-- Name: document_roles document_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_roles
    ADD CONSTRAINT document_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: document_users document_users_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_users
    ADD CONSTRAINT document_users_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(document_id) ON DELETE CASCADE;


--
-- Name: email_layouts email_layouts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_layouts
    ADD CONSTRAINT email_layouts_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: email_notifications email_notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_notifications
    ADD CONSTRAINT email_notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: email_preferences email_preferences_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_preferences
    ADD CONSTRAINT email_preferences_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: email_preferences email_preferences_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_preferences
    ADD CONSTRAINT email_preferences_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: email_templates email_templates_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: email_templates email_templates_layout_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_layout_id_fkey FOREIGN KEY (layout_id) REFERENCES public.email_layouts(id) ON DELETE SET NULL;


--
-- Name: user_profile_roles fk_user_profile_roles_role_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile_roles
    ADD CONSTRAINT fk_user_profile_roles_role_id FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: hardware hardware_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hardware
    ADD CONSTRAINT hardware_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: hib_checklist hib_checklist_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hib_checklist
    ADD CONSTRAINT hib_checklist_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: hib_results hib_results_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hib_results
    ADD CONSTRAINT hib_results_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: key_dates key_dates_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.key_dates
    ADD CONSTRAINT key_dates_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: key_dates key_dates_modified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.key_dates
    ADD CONSTRAINT key_dates_modified_by_fkey FOREIGN KEY (modified_by) REFERENCES public.profiles(id);


--
-- Name: learning_track_assignments learning_track_assignments_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_assignments
    ADD CONSTRAINT learning_track_assignments_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES auth.users(id);


--
-- Name: learning_track_assignments learning_track_assignments_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_assignments
    ADD CONSTRAINT learning_track_assignments_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: learning_track_assignments learning_track_assignments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_assignments
    ADD CONSTRAINT learning_track_assignments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: learning_track_department_assignments learning_track_department_assignments_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_department_assignments
    ADD CONSTRAINT learning_track_department_assignments_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES auth.users(id);


--
-- Name: learning_track_department_assignments learning_track_department_assignments_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_department_assignments
    ADD CONSTRAINT learning_track_department_assignments_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE CASCADE;


--
-- Name: learning_track_department_assignments learning_track_department_assignments_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_department_assignments
    ADD CONSTRAINT learning_track_department_assignments_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: learning_track_lessons learning_track_lessons_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_lessons
    ADD CONSTRAINT learning_track_lessons_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: learning_track_lessons learning_track_lessons_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_lessons
    ADD CONSTRAINT learning_track_lessons_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: learning_track_role_assignments learning_track_role_assignments_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_role_assignments
    ADD CONSTRAINT learning_track_role_assignments_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES auth.users(id);


--
-- Name: learning_track_role_assignments learning_track_role_assignments_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_role_assignments
    ADD CONSTRAINT learning_track_role_assignments_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: learning_track_role_assignments learning_track_role_assignments_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_track_role_assignments
    ADD CONSTRAINT learning_track_role_assignments_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id) ON DELETE CASCADE;


--
-- Name: learning_tracks learning_tracks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_tracks
    ADD CONSTRAINT learning_tracks_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: lesson_answer_translations lesson_answer_translations_answer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answer_translations
    ADD CONSTRAINT lesson_answer_translations_answer_id_fkey FOREIGN KEY (answer_id) REFERENCES public.lesson_answers(id) ON DELETE CASCADE;


--
-- Name: lesson_answer_translations lesson_answer_translations_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answer_translations
    ADD CONSTRAINT lesson_answer_translations_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id);


--
-- Name: lesson_answer_translations lesson_answer_translations_translated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answer_translations
    ADD CONSTRAINT lesson_answer_translations_translated_by_fkey FOREIGN KEY (translated_by) REFERENCES auth.users(id);


--
-- Name: lesson_answers lesson_answers_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_answers
    ADD CONSTRAINT lesson_answers_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.lesson_nodes(id) ON DELETE CASCADE;


--
-- Name: lesson_node_translations lesson_node_translations_language_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_node_translations
    ADD CONSTRAINT lesson_node_translations_language_code_fkey FOREIGN KEY (language_code) REFERENCES public.languages(code);


--
-- Name: lesson_node_translations lesson_node_translations_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_node_translations
    ADD CONSTRAINT lesson_node_translations_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.lesson_nodes(id) ON DELETE CASCADE;


--
-- Name: lesson_node_translations lesson_node_translations_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_node_translations
    ADD CONSTRAINT lesson_node_translations_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id);


--
-- Name: lesson_node_translations lesson_node_translations_translated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_node_translations
    ADD CONSTRAINT lesson_node_translations_translated_by_fkey FOREIGN KEY (translated_by) REFERENCES auth.users(id);


--
-- Name: lesson_nodes lesson_nodes_embedded_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_nodes
    ADD CONSTRAINT lesson_nodes_embedded_lesson_id_fkey FOREIGN KEY (embedded_lesson_id) REFERENCES public.lessons(id);


--
-- Name: lesson_nodes lesson_nodes_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_nodes
    ADD CONSTRAINT lesson_nodes_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: lesson_reminder_counts lesson_reminder_counts_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_counts
    ADD CONSTRAINT lesson_reminder_counts_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: lesson_reminder_counts lesson_reminder_counts_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_counts
    ADD CONSTRAINT lesson_reminder_counts_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: lesson_reminder_counts lesson_reminder_counts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_counts
    ADD CONSTRAINT lesson_reminder_counts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: lesson_reminder_history lesson_reminder_history_email_notification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_history
    ADD CONSTRAINT lesson_reminder_history_email_notification_id_fkey FOREIGN KEY (email_notification_id) REFERENCES public.email_notifications(id) ON DELETE SET NULL;


--
-- Name: lesson_reminder_history lesson_reminder_history_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_history
    ADD CONSTRAINT lesson_reminder_history_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: lesson_reminder_history lesson_reminder_history_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_history
    ADD CONSTRAINT lesson_reminder_history_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: lesson_reminder_history lesson_reminder_history_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_reminder_history
    ADD CONSTRAINT lesson_reminder_history_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: lesson_translations lesson_translations_language_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_translations
    ADD CONSTRAINT lesson_translations_language_code_fkey FOREIGN KEY (language_code) REFERENCES public.languages(code);


--
-- Name: lesson_translations lesson_translations_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_translations
    ADD CONSTRAINT lesson_translations_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: lesson_translations lesson_translations_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_translations
    ADD CONSTRAINT lesson_translations_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id);


--
-- Name: lesson_translations lesson_translations_translated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_translations
    ADD CONSTRAINT lesson_translations_translated_by_fkey FOREIGN KEY (translated_by) REFERENCES auth.users(id);


--
-- Name: lessons lessons_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: lessons lessons_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: notification_history notification_history_email_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_history
    ADD CONSTRAINT notification_history_email_template_id_fkey FOREIGN KEY (email_template_id) REFERENCES public.email_templates(id) ON DELETE SET NULL;


--
-- Name: notification_history notification_history_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_history
    ADD CONSTRAINT notification_history_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.notification_rules(id) ON DELETE SET NULL;


--
-- Name: notification_history notification_history_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_history
    ADD CONSTRAINT notification_history_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: notification_rules notification_rules_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: notification_rules notification_rules_email_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_rules
    ADD CONSTRAINT notification_rules_email_template_id_fkey FOREIGN KEY (email_template_id) REFERENCES public.email_templates(id) ON DELETE CASCADE;


--
-- Name: periodic_reviews periodic_reviews_log_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.periodic_reviews
    ADD CONSTRAINT periodic_reviews_log_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.profiles(id);


--
-- Name: periodic_reviews periodic_reviews_log_submitted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.periodic_reviews
    ADD CONSTRAINT periodic_reviews_log_submitted_by_fkey FOREIGN KEY (submitted_by) REFERENCES public.profiles(id);


--
-- Name: physical_location_access physical_location_access_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physical_location_access
    ADD CONSTRAINT physical_location_access_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.locations(id);


--
-- Name: physical_location_access physical_location_access_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physical_location_access
    ADD CONSTRAINT physical_location_access_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id);


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_language_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_language_fkey FOREIGN KEY (language) REFERENCES public.languages(display_name);


--
-- Name: profiles profiles_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.locations(id);


--
-- Name: profiles profiles_manager_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_manager_fkey FOREIGN KEY (manager) REFERENCES public.user_roles(user_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: profiles profiles_manager_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_manager_fkey1 FOREIGN KEY (manager) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: quiz_attempts quiz_attempts_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quiz_attempts
    ADD CONSTRAINT quiz_attempts_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: quiz_attempts quiz_attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quiz_attempts
    ADD CONSTRAINT quiz_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: roles roles_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE CASCADE;


--
-- Name: template_variable_translations template_variable_translations_variable_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_variable_translations
    ADD CONSTRAINT template_variable_translations_variable_id_fkey FOREIGN KEY (variable_id) REFERENCES public.template_variables(id) ON DELETE CASCADE;


--
-- Name: template_variables template_variables_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_variables
    ADD CONSTRAINT template_variables_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: translation_change_log translation_change_log_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_change_log
    ADD CONSTRAINT translation_change_log_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id);


--
-- Name: translation_change_log translation_change_log_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_change_log
    ADD CONSTRAINT translation_change_log_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id);


--
-- Name: translation_jobs translation_jobs_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_jobs
    ADD CONSTRAINT translation_jobs_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id);


--
-- Name: translation_jobs translation_jobs_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_jobs
    ADD CONSTRAINT translation_jobs_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES auth.users(id);


--
-- Name: translation_jobs translation_jobs_target_language_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_jobs
    ADD CONSTRAINT translation_jobs_target_language_fkey FOREIGN KEY (target_language) REFERENCES public.languages(code);


--
-- Name: user_answer_responses user_answer_responses_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_answer_responses
    ADD CONSTRAINT user_answer_responses_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: user_answer_responses user_answer_responses_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_answer_responses
    ADD CONSTRAINT user_answer_responses_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_behavior_analytics user_behavior_analytics_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_behavior_analytics
    ADD CONSTRAINT user_behavior_analytics_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: user_behavior_analytics user_behavior_analytics_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_behavior_analytics
    ADD CONSTRAINT user_behavior_analytics_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_deletion_audit user_deletion_audit_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_audit
    ADD CONSTRAINT user_deletion_audit_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES auth.users(id);


--
-- Name: user_deletion_audit user_deletion_audit_deleted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_deletion_audit
    ADD CONSTRAINT user_deletion_audit_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES auth.users(id);


--
-- Name: user_departments user_departments_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_departments
    ADD CONSTRAINT user_departments_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE CASCADE;


--
-- Name: user_learning_track_progress user_learning_track_progress_learning_track_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_track_progress
    ADD CONSTRAINT user_learning_track_progress_learning_track_id_fkey FOREIGN KEY (learning_track_id) REFERENCES public.learning_tracks(id) ON DELETE CASCADE;


--
-- Name: user_learning_track_progress user_learning_track_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_track_progress
    ADD CONSTRAINT user_learning_track_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: user_lesson_progress user_lesson_progress_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_lesson_progress
    ADD CONSTRAINT user_lesson_progress_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: user_lesson_progress user_lesson_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_lesson_progress
    ADD CONSTRAINT user_lesson_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id);


--
-- Name: user_phishing_scores user_phishing_scores_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_phishing_scores
    ADD CONSTRAINT user_phishing_scores_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: product_license_assignments user_product_licenses_license_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_license_assignments
    ADD CONSTRAINT user_product_licenses_license_id_fkey FOREIGN KEY (license_id) REFERENCES public.customer_product_licenses(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: product_license_assignments user_product_licenses_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_license_assignments
    ADD CONSTRAINT user_product_licenses_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: email_templates Admins can create custom email templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can create custom email templates" ON public.email_templates FOR INSERT WITH CHECK (((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)) AND (COALESCE(is_system, false) = false)));


--
-- Name: email_layouts Admins can create custom layouts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can create custom layouts" ON public.email_layouts FOR INSERT WITH CHECK (((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)) AND (COALESCE(is_system, false) = false)));


--
-- Name: learning_track_assignments Admins can create learning track assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can create learning track assignments" ON public.learning_track_assignments FOR INSERT TO authenticated WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: email_templates Admins can delete custom email templates only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete custom email templates only" ON public.email_templates FOR DELETE USING (((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)) AND (COALESCE(is_system, false) = false)));


--
-- Name: email_layouts Admins can delete custom layouts only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete custom layouts only" ON public.email_layouts FOR DELETE USING (((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)) AND (COALESCE(is_system, false) = false)));


--
-- Name: translation_change_log Admins can delete translation change log; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete translation change log" ON public.translation_change_log FOR DELETE USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));


--
-- Name: user_deletion_audit Admins can insert user deletion audit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert user deletion audit" ON public.user_deletion_audit FOR INSERT WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: certificates Admins can manage all certificates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage all certificates" ON public.certificates TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_learning_track_progress Admins can manage all learning progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage all learning progress" ON public.user_learning_track_progress TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: quiz_attempts Admins can manage all quiz attempts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage all quiz attempts" ON public.quiz_attempts TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: breach_management_team Admins can manage breach management data; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage breach management data" ON public.breach_management_team USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: breach_team_members Admins can manage breach team members; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage breach team members" ON public.breach_team_members USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: customers Admins can manage customer data; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage customer data" ON public.customers TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: customer_product_licenses Admins can manage customer product licenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage customer product licenses" ON public.customer_product_licenses TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: learning_track_department_assignments Admins can manage department learning track assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage department learning track assignments" ON public.learning_track_department_assignments TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: departments Admins can manage departments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage departments" ON public.departments USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: email_preferences Admins can manage email preferences; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage email preferences" ON public.email_preferences USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: key_dates Admins can manage key dates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage key dates" ON public.key_dates USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: lesson_answer_translations Admins can manage lesson answer translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage lesson answer translations" ON public.lesson_answer_translations USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));


--
-- Name: locations Admins can manage locations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage locations" ON public.locations USING ((auth.role() = 'authenticated'::text));


--
-- Name: org_profile Admins can manage org profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage org profile" ON public.org_profile TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_phishing_scores Admins can manage phishing scores; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage phishing scores" ON public.user_phishing_scores TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: learning_track_role_assignments Admins can manage role learning track assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage role learning track assignments" ON public.learning_track_role_assignments TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: roles Admins can manage roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage roles" ON public.roles USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: notification_rules Admins can manage rules; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage rules" ON public.notification_rules USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: translation_change_log Admins can manage translation change log; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage translation change log" ON public.translation_change_log FOR UPDATE USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));


--
-- Name: user_departments Admins can manage user departments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage user departments" ON public.user_departments USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_profile_roles Admins can manage user profile roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage user profile roles" ON public.user_profile_roles USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: email_layouts Admins can update email layouts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update email layouts" ON public.email_layouts FOR UPDATE USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: email_templates Admins can update email templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update email templates" ON public.email_templates FOR UPDATE USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_roles Admins can update user roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update user roles" ON public.user_roles FOR UPDATE TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: certificates Admins can view all certificates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all certificates" ON public.certificates FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: notification_history Admins can view all notification history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all notification history" ON public.notification_history FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_phishing_scores Admins can view all phishing scores; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all phishing scores" ON public.user_phishing_scores FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: quiz_attempts Admins can view all quiz attempts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all quiz attempts" ON public.quiz_attempts FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: lesson_reminder_history Admins can view all reminder history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all reminder history" ON public.lesson_reminder_history FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_roles Admins can view all user roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all user roles" ON public.user_roles FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: customers Admins can view customer data; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view customer data" ON public.customers FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: customer_product_licenses Admins can view customer product licenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view customer product licenses" ON public.customer_product_licenses FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: email_layouts Admins can view email layouts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view email layouts" ON public.email_layouts FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: email_templates Admins can view email templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view email templates" ON public.email_templates FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: org_profile Admins can view org profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view org profile" ON public.org_profile FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: notification_rules Admins can view rules; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view rules" ON public.notification_rules FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: translation_change_log Admins can view translation change log; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view translation change log" ON public.translation_change_log FOR SELECT USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));


--
-- Name: user_deletion_audit Admins can view user deletion audit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view user deletion audit" ON public.user_deletion_audit FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: template_variables All authenticated users can view active template variables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "All authenticated users can view active template variables" ON public.template_variables FOR SELECT USING (((auth.role() = 'authenticated'::text) AND (is_active = true)));


--
-- Name: template_variable_translations All authenticated users can view variable translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "All authenticated users can view variable translations" ON public.template_variable_translations FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: email_templates Allow admin users to manage email templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow admin users to manage email templates" ON public.email_templates USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_lesson_progress Allow anonymous lesson progress management for development; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow anonymous lesson progress management for development" ON public.user_lesson_progress USING (true);


--
-- Name: email_templates Allow authenticated users to read email templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow authenticated users to read email templates" ON public.email_templates FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: lesson_answers Allow lesson answer management; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow lesson answer management" ON public.lesson_answers USING (true) WITH CHECK (true);


--
-- Name: departments Anyone can view departments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view departments" ON public.departments FOR SELECT USING (true);


--
-- Name: languages Anyone can view languages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view languages" ON public.languages FOR SELECT USING (true);


--
-- Name: roles Anyone can view roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view roles" ON public.roles FOR SELECT USING (true);


--
-- Name: template_variable_translations Anyone can view template variable translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view template variable translations" ON public.template_variable_translations FOR SELECT USING (true);


--
-- Name: template_variables Anyone can view template variables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone can view template variables" ON public.template_variables FOR SELECT USING (true);


--
-- Name: physical_location_access Authenticated users can create physical location access records; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can create physical location access records" ON public.physical_location_access FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: physical_location_access Authenticated users can delete physical location access records; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can delete physical location access records" ON public.physical_location_access FOR DELETE TO authenticated USING (true);


--
-- Name: physical_location_access Authenticated users can update physical location access records; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update physical location access records" ON public.physical_location_access FOR UPDATE TO authenticated USING (true);


--
-- Name: csba_master Authenticated users can view CSBA master; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can view CSBA master" ON public.csba_master FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: physical_location_access Authenticated users can view all physical location access recor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can view all physical location access recor" ON public.physical_location_access FOR SELECT TO authenticated USING (true);


--
-- Name: key_dates Authenticated users can view key dates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can view key dates" ON public.key_dates FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: products Enable all for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable all for authenticated users only" ON public.products TO authenticated USING (true) WITH CHECK (true);


--
-- Name: product_license_assignments Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.product_license_assignments FOR SELECT USING (true);


--
-- Name: products Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.products FOR SELECT USING (true);


--
-- Name: lesson_node_translations Everyone can view lesson node translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Everyone can view lesson node translations" ON public.lesson_node_translations FOR SELECT USING (true);


--
-- Name: lesson_translations Everyone can view lesson translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Everyone can view lesson translations" ON public.lesson_translations FOR SELECT USING (true);


--
-- Name: lesson_nodes Everyone can view nodes of published lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Everyone can view nodes of published lessons" ON public.lesson_nodes FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.lessons
  WHERE ((lessons.id = lesson_nodes.lesson_id) AND ((lessons.status = 'published'::text) OR public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))))));


--
-- Name: lessons Everyone can view published lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Everyone can view published lessons" ON public.lessons FOR SELECT USING (((status = 'published'::text) OR public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: account_inventory Managers can view accounts for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view accounts for their department users" ON public.account_inventory FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND (user_id IS NOT NULL) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: certificates Managers can view certificates for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view certificates for their department users" ON public.certificates FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: user_departments Managers can view department assignments for their departments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view department assignments for their departments" ON public.user_departments FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND (department_id IN ( SELECT departments.id
   FROM public.departments
  WHERE (departments.manager_id = auth.uid())))));


--
-- Name: learning_track_department_assignments Managers can view department learning track assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view department learning track assignments" ON public.learning_track_department_assignments FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND (EXISTS ( SELECT 1
   FROM public.user_departments ud
  WHERE ((ud.department_id = learning_track_department_assignments.department_id) AND public.is_user_in_managed_department(auth.uid(), ud.user_id))))));


--
-- Name: document_assignments Managers can view document assignments for their department use; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view document assignments for their department use" ON public.document_assignments FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: hardware Managers can view hardware for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view hardware for their department users" ON public.hardware FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: hardware_inventory Managers can view hardware for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view hardware for their department users" ON public.hardware_inventory FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND (EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.full_name = hardware_inventory.asset_owner) AND public.is_user_in_managed_department(auth.uid(), p.id))))));


--
-- Name: user_learning_track_progress Managers can view learning progress for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view learning progress for their department users" ON public.user_learning_track_progress FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: learning_track_assignments Managers can view learning track assignments for their departme; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view learning track assignments for their departme" ON public.learning_track_assignments FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: user_phishing_scores Managers can view phishing scores for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view phishing scores for their department users" ON public.user_phishing_scores FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: profiles Managers can view profiles in their departments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view profiles in their departments" ON public.profiles FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), id)));


--
-- Name: user_learning_track_progress Managers can view progress for their department users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Managers can view progress for their department users" ON public.user_learning_track_progress FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'manager'::public.app_role) AND public.is_user_in_managed_department(auth.uid(), user_id)));


--
-- Name: breach_management_team Only admins can view breach management data; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can view breach management data" ON public.breach_management_team FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: breach_team_members Only admins can view breach team members; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can view breach team members" ON public.breach_team_members FOR SELECT USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: user_roles Only super admins can modify roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only super admins can modify roles" ON public.user_roles USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));


--
-- Name: user_learning_track_progress Service role can insert learning progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can insert learning progress" ON public.user_learning_track_progress FOR INSERT WITH CHECK ((auth.role() = 'service_role'::text));


--
-- Name: profiles Service role can insert profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can insert profiles" ON public.profiles FOR INSERT WITH CHECK ((auth.role() = 'service_role'::text));


--
-- Name: lesson_reminder_counts Service role can manage all reminder counts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage all reminder counts" ON public.lesson_reminder_counts USING ((auth.role() = 'service_role'::text));


--
-- Name: email_layouts Service role can manage email layouts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage email layouts" ON public.email_layouts USING (true) WITH CHECK (true);


--
-- Name: email_preferences Service role can manage email preferences; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage email preferences" ON public.email_preferences USING (true) WITH CHECK (true);


--
-- Name: email_templates Service role can manage email templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage email templates" ON public.email_templates USING (true) WITH CHECK (true);


--
-- Name: notification_history Service role can manage notification history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage notification history" ON public.notification_history USING (true) WITH CHECK (true);


--
-- Name: lesson_reminder_history Service role can manage reminder history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage reminder history" ON public.lesson_reminder_history USING (true) WITH CHECK (true);


--
-- Name: notification_rules Service role can manage rules; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role can manage rules" ON public.notification_rules USING (true) WITH CHECK (true);


--
-- Name: learning_tracks Super admins and authors can create learning tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can create learning tracks" ON public.learning_tracks FOR INSERT TO authenticated WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: lessons Super admins and authors can create lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can create lessons" ON public.lessons FOR INSERT WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: learning_tracks Super admins and authors can delete learning tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can delete learning tracks" ON public.learning_tracks FOR DELETE TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: lessons Super admins and authors can delete lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can delete lessons" ON public.lessons FOR DELETE USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: lesson_node_translations Super admins and authors can manage lesson node translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can manage lesson node translations" ON public.lesson_node_translations USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: lesson_nodes Super admins and authors can manage lesson nodes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can manage lesson nodes" ON public.lesson_nodes USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: lesson_translations Super admins and authors can manage lesson translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can manage lesson translations" ON public.lesson_translations USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: learning_track_lessons Super admins and authors can manage track lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can manage track lessons" ON public.learning_track_lessons TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: learning_tracks Super admins and authors can update learning tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can update learning tracks" ON public.learning_tracks FOR UPDATE TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: lessons Super admins and authors can update lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins and authors can update lessons" ON public.lessons FOR UPDATE USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'author'::public.app_role)));


--
-- Name: profiles Super admins can manage all profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins can manage all profiles" ON public.profiles TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role))) WITH CHECK ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: languages Super admins can manage languages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins can manage languages" ON public.languages USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));


--
-- Name: profiles Super admins can view all profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Super admins can view all profiles" ON public.profiles FOR SELECT TO authenticated USING ((public.has_role(auth.uid(), 'super_admin'::public.app_role) OR public.has_role(auth.uid(), 'client_admin'::public.app_role)));


--
-- Name: translation_change_log System can insert translation change log entries; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "System can insert translation change log entries" ON public.translation_change_log FOR INSERT WITH CHECK (true);


--
-- Name: hib_results Users can create their own HIB results; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can create their own HIB results" ON public.hib_results FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: hib_checklist Users can delete their own HIB checklist items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own HIB checklist items" ON public.hib_checklist FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: hib_results Users can delete their own HIB results; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own HIB results" ON public.hib_results FOR DELETE USING ((auth.uid() = user_id));


--
-- Name: hib_checklist Users can insert their own HIB checklist items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own HIB checklist items" ON public.hib_checklist FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: user_answer_responses Users can insert their own answer responses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own answer responses" ON public.user_answer_responses FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: user_behavior_analytics Users can insert their own behavior analytics; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own behavior analytics" ON public.user_behavior_analytics FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: certificates Users can insert their own certificates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own certificates" ON public.certificates FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: email_notifications Users can insert their own email notifications; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own email notifications" ON public.email_notifications FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: user_learning_track_progress Users can insert their own learning track progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own learning track progress" ON public.user_learning_track_progress FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: quiz_attempts Users can insert their own quiz attempts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own quiz attempts" ON public.quiz_attempts FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: csba_answers Users can manage their own CSBA answers; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage their own CSBA answers" ON public.csba_answers USING ((auth.uid() = user_id));


--
-- Name: user_lesson_progress Users can manage their own lesson progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage their own lesson progress" ON public.user_lesson_progress USING ((auth.uid() = user_id));


--
-- Name: hib_checklist Users can update their own HIB checklist items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own HIB checklist items" ON public.hib_checklist FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: hib_results Users can update their own HIB results; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own HIB results" ON public.hib_results FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: document_assignments Users can update their own assignment status; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own assignment status" ON public.document_assignments FOR UPDATE USING (((auth.uid() = user_id) AND (status = ANY (ARRAY['Not started'::text, 'In progress'::text, 'Completed'::text]))));


--
-- Name: learning_track_assignments Users can update their own assignment status; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own assignment status" ON public.learning_track_assignments FOR UPDATE USING ((auth.uid() = user_id));


--
-- Name: user_departments Users can update their own department assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own department assignments" ON public.user_departments FOR UPDATE TO authenticated USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: user_learning_track_progress Users can update their own learning progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own learning progress" ON public.user_learning_track_progress FOR UPDATE TO authenticated USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: user_learning_track_progress Users can update their own learning track progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own learning track progress" ON public.user_learning_track_progress FOR UPDATE TO authenticated USING ((auth.uid() = user_id));


--
-- Name: profiles Users can update their own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own profile" ON public.profiles FOR UPDATE TO authenticated USING ((auth.uid() = id)) WITH CHECK ((auth.uid() = id));


--
-- Name: roles Users can view active roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view active roles" ON public.roles FOR SELECT USING ((is_active = true));


--
-- Name: document_departments Users can view document departments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view document departments" ON public.document_departments FOR SELECT USING (true);


--
-- Name: document_roles Users can view document roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view document roles" ON public.document_roles FOR SELECT USING (true);


--
-- Name: document_users Users can view document users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view document users" ON public.document_users FOR SELECT USING (true);


--
-- Name: documents Users can view documents; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view documents" ON public.documents FOR SELECT USING (true);


--
-- Name: lesson_answer_translations Users can view lesson answer translations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view lesson answer translations" ON public.lesson_answer_translations FOR SELECT USING (true);


--
-- Name: locations Users can view locations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view locations" ON public.locations FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: learning_tracks Users can view published learning tracks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view published learning tracks" ON public.learning_tracks FOR SELECT USING ((status = 'published'::text));


--
-- Name: learning_track_role_assignments Users can view role learning track assignments for their roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view role learning track assignments for their roles" ON public.learning_track_role_assignments FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_profile_roles upr
  WHERE ((upr.role_id = learning_track_role_assignments.role_id) AND (upr.user_id = auth.uid())))));


--
-- Name: hib_checklist Users can view their own HIB checklist items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own HIB checklist items" ON public.hib_checklist FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: hib_results Users can view their own HIB results; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own HIB results" ON public.hib_results FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_answer_responses Users can view their own answer responses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own answer responses" ON public.user_answer_responses FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: document_assignments Users can view their own assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own assignments" ON public.document_assignments FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: learning_track_assignments Users can view their own assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own assignments" ON public.learning_track_assignments FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_behavior_analytics Users can view their own behavior analytics; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own behavior analytics" ON public.user_behavior_analytics FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: certificates Users can view their own certificates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own certificates" ON public.certificates FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: user_departments Users can view their own department assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own department assignments" ON public.user_departments FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: email_notifications Users can view their own email notifications; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own email notifications" ON public.email_notifications FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: hardware Users can view their own hardware; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own hardware" ON public.hardware FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_learning_track_progress Users can view their own learning progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own learning progress" ON public.user_learning_track_progress FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: user_learning_track_progress Users can view their own learning track progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own learning track progress" ON public.user_learning_track_progress FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: notification_history Users can view their own notification history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own notification history" ON public.notification_history FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_phishing_scores Users can view their own phishing scores; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own phishing scores" ON public.user_phishing_scores FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: profiles Users can view their own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own profile" ON public.profiles FOR SELECT TO authenticated USING ((auth.uid() = id));


--
-- Name: user_profile_roles Users can view their own profile roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own profile roles" ON public.user_profile_roles FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: quiz_attempts Users can view their own quiz attempts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own quiz attempts" ON public.quiz_attempts FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: lesson_reminder_counts Users can view their own reminder counts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own reminder counts" ON public.lesson_reminder_counts FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: lesson_reminder_history Users can view their own reminder history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own reminder history" ON public.lesson_reminder_history FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_roles Users can view their own role; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own role" ON public.user_roles FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: user_profile_roles Users can view their own roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own roles" ON public.user_profile_roles FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_roles Users can view their own roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own roles" ON public.user_roles FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: learning_track_lessons Users can view track lessons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view track lessons" ON public.learning_track_lessons FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.learning_tracks
  WHERE ((learning_tracks.id = learning_track_lessons.learning_track_id) AND (learning_tracks.status = 'published'::text)))));


--
-- Name: account_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.account_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: breach_management_team; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.breach_management_team ENABLE ROW LEVEL SECURITY;

--
-- Name: breach_team_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.breach_team_members ENABLE ROW LEVEL SECURITY;

--
-- Name: certificates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.certificates ENABLE ROW LEVEL SECURITY;

--
-- Name: csba_answers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.csba_answers ENABLE ROW LEVEL SECURITY;

--
-- Name: csba_master; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.csba_master ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_product_licenses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_product_licenses ENABLE ROW LEVEL SECURITY;

--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: departments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;

--
-- Name: document_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: document_departments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_departments ENABLE ROW LEVEL SECURITY;

--
-- Name: document_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: document_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_users ENABLE ROW LEVEL SECURITY;

--
-- Name: documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

--
-- Name: email_layouts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.email_layouts ENABLE ROW LEVEL SECURITY;

--
-- Name: email_notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.email_notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: email_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.email_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: hardware; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hardware ENABLE ROW LEVEL SECURITY;

--
-- Name: hardware_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hardware_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: hib_checklist; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hib_checklist ENABLE ROW LEVEL SECURITY;

--
-- Name: hib_results; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hib_results ENABLE ROW LEVEL SECURITY;

--
-- Name: key_dates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.key_dates ENABLE ROW LEVEL SECURITY;

--
-- Name: languages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.languages ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_track_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.learning_track_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_track_department_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.learning_track_department_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_track_lessons; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.learning_track_lessons ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_track_role_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.learning_track_role_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_tracks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.learning_tracks ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_answer_translations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_answer_translations ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_answers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_answers ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_node_translations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_node_translations ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_nodes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_nodes ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_reminder_counts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_reminder_counts ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_reminder_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_reminder_history ENABLE ROW LEVEL SECURITY;

--
-- Name: lesson_translations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lesson_translations ENABLE ROW LEVEL SECURITY;

--
-- Name: lessons; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lessons ENABLE ROW LEVEL SECURITY;

--
-- Name: locations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notification_history ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notification_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: org_profile; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.org_profile ENABLE ROW LEVEL SECURITY;

--
-- Name: org_sig_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.org_sig_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: periodic_reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.periodic_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: physical_location_access; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.physical_location_access ENABLE ROW LEVEL SECURITY;

--
-- Name: product_license_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_license_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quiz_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

--
-- Name: software_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.software_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: template_variable_translations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.template_variable_translations ENABLE ROW LEVEL SECURITY;

--
-- Name: template_variables; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.template_variables ENABLE ROW LEVEL SECURITY;

--
-- Name: translation_change_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.translation_change_log ENABLE ROW LEVEL SECURITY;

--
-- Name: translation_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.translation_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: user_answer_responses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_answer_responses ENABLE ROW LEVEL SECURITY;

--
-- Name: user_behavior_analytics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_behavior_analytics ENABLE ROW LEVEL SECURITY;

--
-- Name: user_deletion_audit; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_deletion_audit ENABLE ROW LEVEL SECURITY;

--
-- Name: user_departments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_departments ENABLE ROW LEVEL SECURITY;

--
-- Name: user_learning_track_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_learning_track_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: user_lesson_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_lesson_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: user_phishing_scores; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_phishing_scores ENABLE ROW LEVEL SECURITY;

--
-- Name: user_profile_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_profile_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: user_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict SxTa4dJQhePpmpSjMETdT87JZlB1otDZxCFH61b1cyFIgNJgs2SueOrxECQEDEV

