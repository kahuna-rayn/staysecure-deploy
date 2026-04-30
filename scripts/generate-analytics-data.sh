#!/usr/bin/env bash

# Generate Analytics Demo Data
# Inserts synthetic rows into analytics tables using existing profile IDs and published content.
#
# Preferred profiles: analytics rows are sampled from these IDs (when they exist in
# public.profiles) plus other profiles until the pool reaches nine users — not from
# the entire tenant user list.
#
# UUID | full_name | email (reference only; rows key off id)
# 16ecc3d7-9b51-4309-ba95-54ede97c2d11 | Sasikumar Balakrishnan | sasikumar.balakrishnan@raynsecure.com
# d8527f9b-66f7-4e78-a481-a603fdb8b567 | ANDREW ONG WAI KIN | andrew.ongwk@gmail.com
# 8f5197f0-f2d2-46e6-bbb3-f6971414134c | Naresh Super Admin | naresh.parshotam@raynsecure.com
# e5b43f83-f2cb-49c2-a036-558c2336d5a7 | Richard Super Admin Dev | richard.pereira@raynsecure.com
# e0bf6e6b-41b7-40e1-848d-b233bbb358a7 | Yew Hong Leong | yewhong.leong@raynsecure.com
#
# Prerequisites: PGPASSWORD (optionally from .env / .env.local in the script directory or parent).
#
# Staging only (matches learn/secrets/projects.conf STAGING_REF) — avoids accidental prod/dev runs.
#
# Usage:
#   ./generate-analytics-data.sh                    # staging, default counts
#   ./generate-analytics-data.sh --staging
#   ./generate-analytics-data.sh --staging 400 800
#   ./generate-analytics-data.sh 500 1000             # staging + custom counts
#   ./generate-analytics-data.sh "$STAGING_REF" ...   # optional explicit ref if it equals staging
#
# Optional record counts (up to 5 integers): progress, behavior, quiz, track, assignment
# Defaults: 500 1000 300 150 200

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECTS_CONF="${PROJECT_ROOT}/learn/secrets/projects.conf"
REGION="${REGION:-ap-southeast-1}"

usage() {
    echo "Usage: $0 [--staging] [count1 [count2 [count3 [count4 [count5]]]]]" >&2
    echo "" >&2
    echo "Staging only — uses STAGING_REF from learn/secrets/projects.conf." >&2
    echo "For other environments use run-migrations.sh and manual SQL, not this script." >&2
    echo "" >&2
    echo "Optional counts (integers): lesson_progress, behavior, quiz, track_progress, assignments" >&2
    echo "Defaults: 500 1000 300 150 200" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  PGPASSWORD=xxx $0" >&2
    echo "  $0 --staging 400 800" >&2
    echo "  $0 500 1000 300 150 200" >&2
    exit 1
}

if [ ! -f "${PROJECTS_CONF}" ]; then
    echo -e "${RED}Error: projects.conf not found at ${PROJECTS_CONF}${NC}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${PROJECTS_CONF}"

for _help in "$@"; do
    case "$_help" in
        -h|--help) usage ;;
    esac
done

# Optional PGPASSWORD from env files (run-migrations does not do this; kept for compatibility)
for envfile in "${SCRIPT_DIR}/.env.local" "${SCRIPT_DIR}/.env" "${PROJECT_ROOT}/.env.local" "${PROJECT_ROOT}/.env"; do
    if [ -z "${PGPASSWORD:-}" ] && [ -f "${envfile}" ]; then
        # shellcheck source=/dev/null
        set +u
        source "${envfile}"
        set -u
        break
    fi
done

if [ -z "${PGPASSWORD:-}" ]; then
    echo -e "${RED}Error: PGPASSWORD is not set${NC}" >&2
    echo "Export it before running: export PGPASSWORD=<your-db-password>" >&2
    exit 1
fi

REFS=()
COUNT_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --staging)
            REFS+=("$STAGING_REF")
            ;;
        --dev|--master|--all-production|--all)
            echo -e "${RED}Error: analytics demo generation is restricted to staging (${STAGING_REF}) only.${NC}" >&2
            echo "  Other targets: do not use this script (use run-migrations.sh / bespoke tooling)." >&2
            exit 1
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo -e "${RED}Unknown flag: ${arg}${NC}" >&2
            usage
            ;;
        *)
            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                COUNT_ARGS+=("$arg")
            else
                REFS+=("$arg")
            fi
            ;;
    esac
done

if [ ${#REFS[@]} -eq 0 ]; then
    REFS+=("$STAGING_REF")
fi

for ref in "${REFS[@]}"; do
    if [ "$ref" != "$STAGING_REF" ]; then
        echo -e "${RED}Error: ref ${ref} is not staging. Only STAGING_REF (${STAGING_REF}) is allowed.${NC}" >&2
        exit 1
    fi
done

PROGRESS_RECORDS=${COUNT_ARGS[0]:-500}
BEHAVIOR_RECORDS=${COUNT_ARGS[1]:-1000}
QUIZ_RECORDS=${COUNT_ARGS[2]:-300}
TRACK_RECORDS=${COUNT_ARGS[3]:-150}
ASSIGNMENT_RECORDS=${COUNT_ARGS[4]:-200}

if [ ${#COUNT_ARGS[@]} -gt 5 ]; then
    echo -e "${YELLOW}Warning: ignoring extra count arguments (only first five used)${NC}" >&2
fi

# Deduplicate refs (preserving order; bash 3 compatible)
UNIQUE_REFS=()
for ref in "${REFS[@]}"; do
    _dup=false
    for _existing in "${UNIQUE_REFS[@]:-}"; do
        [ "$_existing" = "$ref" ] && _dup=true && break
    done
    $_dup || UNIQUE_REFS+=("$ref")
done

connect_args_for_ref() {
    local ref="$1"
    local db_host="db.${ref}.supabase.co"
    local pooler_host="${POOLER_HOST:-aws-1-${REGION}.pooler.supabase.com}"
    local resolved
    resolved=$(dig AAAA +short "${db_host}" 2>/dev/null | grep -v '^\.' | head -1 || true)
    if [ -n "$resolved" ] && ping6 -c 1 -W 2 "${resolved}" &>/dev/null 2>&1; then
        export PGHOSTADDR="${resolved}"
        echo "host=${db_host} port=6543 user=postgres dbname=postgres sslmode=require"
    else
        unset PGHOSTADDR
        echo "host=${pooler_host} port=5432 user=postgres.${ref} dbname=postgres sslmode=require"
    fi
}

FAILED=()

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  generate-analytics-data (staging only)${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  ${YELLOW}Project: ${STAGING_REF}${NC}"
echo -e "  Counts: progress=${PROGRESS_RECORDS} behavior=${BEHAVIOR_RECORDS} quiz=${QUIZ_RECORDS} track=${TRACK_RECORDS} assignments=${ASSIGNMENT_RECORDS}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

for PROJECT_REF in "${UNIQUE_REFS[@]}"; do
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}Project: ${PROJECT_REF}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"

    CONNECTION_STRING=$(connect_args_for_ref "${PROJECT_REF}")
    echo -e "  Connection: ${CONNECTION_STRING}"

    echo -e "${GREEN}Generating analytics demo data for project: ${PROJECT_REF}${NC}"
    echo ""

    echo -e "${YELLOW}Checking available users (profiles)...${NC}"
    USER_COUNT=$(psql "${CONNECTION_STRING}" -tAq -c "SELECT COUNT(*)::text FROM public.profiles;" 2>&1) || {
        echo -e "${RED}✗ Cannot query profiles on ${PROJECT_REF}${NC}"
        FAILED+=("${PROJECT_REF}")
        continue
    }
    USER_COUNT=$(echo "${USER_COUNT}" | tr -d ' ')
    echo -e "  Found ${USER_COUNT} users in profiles table"

    if [ "${USER_COUNT}" -eq "0" ]; then
        echo -e "${RED}Error: No users found in profiles table. Please import profiles first.${NC}"
        FAILED+=("${PROJECT_REF}")
        continue
    fi

    echo -e "${YELLOW}Sample users (preferred pool — five listed IDs + others to max 9):${NC}"
    psql "${CONNECTION_STRING}" -t -c "
WITH preferred AS (
  SELECT u.id, u.ord FROM unnest(ARRAY[
    '16ecc3d7-9b51-4309-ba95-54ede97c2d11'::uuid,
    'd8527f9b-66f7-4e78-a481-a603fdb8b567'::uuid,
    '8f5197f0-f2d2-46e6-bbb3-f6971414134c'::uuid,
    'e5b43f83-f2cb-49c2-a036-558c2336d5a7'::uuid,
    'e0bf6e6b-41b7-40e1-848d-b233bbb358a7'::uuid
  ]) WITH ORDINALITY AS u(id, ord)
),
pref_found AS (
  SELECT pf.id, pf.ord
  FROM preferred pf
  INNER JOIN public.profiles pr ON pr.id = pf.id
),
pref_arr AS (
  SELECT COALESCE(
    (SELECT array_agg(id ORDER BY ord) FROM pref_found),
    ARRAY[]::uuid[]
  ) AS ids
),
sizes AS (
  SELECT ids, GREATEST(0, 9 - cardinality(ids))::bigint AS need FROM pref_arr
),
extras_ranked AS (
  SELECT p.id, ROW_NUMBER() OVER (ORDER BY p.id) AS rn
  FROM public.profiles p
  CROSS JOIN sizes s
  WHERE NOT (p.id = ANY(s.ids))
),
extra AS (
  SELECT er.id FROM extras_ranked er
  CROSS JOIN sizes s
  WHERE er.rn <= s.need
)
(SELECT pr.id, pr.full_name, pr.email FROM pref_found pf
JOIN public.profiles pr ON pr.id = pf.id
ORDER BY pf.ord)
UNION ALL
SELECT pr.id, pr.full_name, pr.email FROM extra e JOIN public.profiles pr ON pr.id = e.id;
" 2>&1 | while read -r line; do
        if [ -n "$line" ]; then
            echo "  $line"
        fi
    done

    LESSON_COUNT=$(psql "${CONNECTION_STRING}" -tAq -c "SELECT COUNT(*)::text FROM public.lessons WHERE status = 'published';" | tr -d ' ')
    TRACK_COUNT=$(psql "${CONNECTION_STRING}" -tAq -c "SELECT COUNT(*)::text FROM public.learning_tracks WHERE status = 'published';" | tr -d ' ')
    QUIZ_LESSON_COUNT=$(psql "${CONNECTION_STRING}" -tAq -c "SELECT COUNT(*)::text FROM public.lessons WHERE status = 'published' AND lesson_type = 'quiz';" | tr -d ' ')

    echo ""
    echo -e "${YELLOW}Available content:${NC}"
    echo "  - Published lessons: ${LESSON_COUNT}"
    echo "  - Published learning tracks: ${TRACK_COUNT}"
    echo "  - Quiz lessons: ${QUIZ_LESSON_COUNT}"

    if [ "${LESSON_COUNT}" -eq "0" ]; then
        echo -e "${RED}Error: No published lessons found. Please import lessons first.${NC}"
        FAILED+=("${PROJECT_REF}")
        continue
    fi

    echo ""
    echo -e "${YELLOW}Preparing analytics tables (dropping FK constraints to auth.users)...${NC}"
    ANALYTICS_TABLES=("user_behavior_analytics" "quiz_attempts" "user_learning_track_progress" "learning_track_assignments" "certificates")

    for table in "${ANALYTICS_TABLES[@]}"; do
        FK_CONSTRAINTS=$(psql "${CONNECTION_STRING}" -tAq -c "SELECT conname FROM pg_constraint WHERE conrelid = 'public.${table}'::regclass AND contype = 'f' AND confrelid = 'auth.users'::regclass;" 2>&1 | grep -v '^$' || true)
        if [ -n "$FK_CONSTRAINTS" ]; then
            echo "$FK_CONSTRAINTS" | while IFS= read -r FK_CONSTRAINT; do
                FK_CONSTRAINT=$(echo "$FK_CONSTRAINT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ -n "$FK_CONSTRAINT" ]; then
                    echo -e "  Dropping FK constraint on ${table}: ${FK_CONSTRAINT}"
                    psql "${CONNECTION_STRING}" \
                        --command "ALTER TABLE public.${table} DROP CONSTRAINT IF EXISTS \"${FK_CONSTRAINT}\";" >/dev/null 2>&1
                fi
            done
        fi
    done

    echo ""
    echo "Records to generate:"
    echo "  - user_lesson_progress: ${PROGRESS_RECORDS}"
    echo "  - user_behavior_analytics: ${BEHAVIOR_RECORDS}"
    echo "  - quiz_attempts: ${QUIZ_RECORDS}"
    echo "  - user_learning_track_progress: ${TRACK_RECORDS}"
    echo "  - learning_track_assignments: ${ASSIGNMENT_RECORDS}"

    SQL_FILE=$(mktemp)
    cat > "${SQL_FILE}" <<EOF
-- Generate Analytics Demo Data
DO \$\$
DECLARE
    user_count INTEGER;
    lesson_count INTEGER;
    track_count INTEGER;
    quiz_lesson_count INTEGER;
    preferred_order CONSTANT uuid[] := ARRAY[
        '16ecc3d7-9b51-4309-ba95-54ede97c2d11'::uuid,
        'd8527f9b-66f7-4e78-a481-a603fdb8b567'::uuid,
        '8f5197f0-f2d2-46e6-bbb3-f6971414134c'::uuid,
        'e5b43f83-f2cb-49c2-a036-558c2336d5a7'::uuid,
        'e0bf6e6b-41b7-40e1-848d-b233bbb358a7'::uuid
    ];
    pool_cap CONSTANT int := 9;
    pref_in_db UUID[];
    extra_ids UUID[];
    profile_ids UUID[];
    certificate_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO user_count FROM public.profiles;
    SELECT COUNT(*) INTO lesson_count FROM public.lessons WHERE status = 'published';
    SELECT COUNT(*) INTO track_count FROM public.learning_tracks WHERE status = 'published';
    SELECT COUNT(*) INTO quiz_lesson_count FROM public.lessons WHERE status = 'published' AND lesson_type = 'quiz';

    SELECT COALESCE(
        ARRAY_AGG(u.pid ORDER BY u.o),
        ARRAY[]::uuid[]
    ) INTO pref_in_db
    FROM unnest(preferred_order) WITH ORDINALITY AS u(pid, o)
    WHERE EXISTS (SELECT 1 FROM public.profiles pr WHERE pr.id = u.pid);

    SELECT COALESCE(
        ARRAY_AGG(x.id ORDER BY x.id),
        ARRAY[]::uuid[]
    ) INTO extra_ids
    FROM (
        SELECT ranked.id
        FROM (
            SELECT pr.id,
                   ROW_NUMBER() OVER (ORDER BY pr.id) AS rn
            FROM public.profiles pr
            WHERE NOT (pr.id = ANY(pref_in_db))
        ) ranked
        WHERE ranked.rn <= GREATEST(0, pool_cap - COALESCE(array_length(pref_in_db, 1), 0))
    ) x;

    profile_ids := pref_in_db || extra_ids;

    IF profile_ids IS NULL OR COALESCE(array_length(profile_ids, 1), 0) = 0 THEN
        SELECT ARRAY_AGG(id) INTO profile_ids FROM public.profiles;
        RAISE NOTICE 'Preferred pool empty; using all % profile IDs', COALESCE(array_length(profile_ids, 1), 0);
    ELSE
        RAISE NOTICE 'Sampling analytics for % profile(s) (preferred + others, cap %)',
            COALESCE(array_length(profile_ids, 1), 0),
            pool_cap;
    END IF;

    IF profile_ids IS NULL OR COALESCE(array_length(profile_ids, 1), 0) = 0 THEN
        RAISE EXCEPTION 'No profile IDs available for analytics generation';
    END IF;

    RAISE NOTICE 'Found % users (profiles), % lessons, % tracks, % quiz lessons', user_count, lesson_count, track_count, quiz_lesson_count;

    INSERT INTO public.user_lesson_progress (user_id, lesson_id, completed_at, started_at, completed_nodes, last_accessed)
    SELECT
        profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
        (SELECT id FROM public.lessons WHERE status = 'published' ORDER BY RANDOM() LIMIT 1),
        CASE
            WHEN random() > 0.3 THEN
                CASE
                    WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
                    ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
                END
            ELSE NULL
        END,
        CASE
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') - (random() * INTERVAL '2 hours')
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') - (random() * INTERVAL '2 hours')
        END,
        CASE WHEN random() > 0.3 THEN ARRAY['node1', 'node2', 'node3']::text[] ELSE ARRAY[]::text[] END,
        CASE
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '7 days')
            ELSE NOW() - (random() * INTERVAL '30 days')
        END
    FROM generate_series(1, ${PROGRESS_RECORDS})
    ON CONFLICT (user_id, lesson_id) DO NOTHING;

    RAISE NOTICE 'Generated user_lesson_progress records';

    INSERT INTO public.user_behavior_analytics (user_id, lesson_id, session_id, total_time_spent, nodes_visited, completion_path, created_at, completed_at)
    SELECT
        profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
        (SELECT id FROM public.lessons WHERE status = 'published' ORDER BY RANDOM() LIMIT 1),
        gen_random_uuid()::text,
        floor(random() * 3600)::INTEGER,
        ARRAY['node_' || floor(random() * 10 + 1)::text, 'node_' || floor(random() * 10 + 1)::text, 'node_' || floor(random() * 10 + 1)::text]::text[],
        ARRAY['path_' || floor(random() * 5 + 1)::text]::text[],
        CASE
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
        END,
        CASE
            WHEN random() > 0.5 THEN
                CASE
                    WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
                    ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
                END
            ELSE NULL
        END
    FROM generate_series(1, ${BEHAVIOR_RECORDS});

    RAISE NOTICE 'Generated user_behavior_analytics records';

    IF quiz_lesson_count > 0 THEN
        INSERT INTO public.quiz_attempts (user_id, lesson_id, attempt_number, percentage_score, correct_answers, total_questions, passed, created_at, completed_at)
        SELECT
            profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
            (SELECT id FROM public.lessons WHERE status = 'published' AND lesson_type = 'quiz' ORDER BY RANDOM() LIMIT 1),
            floor(random() * 3 + 1)::INTEGER,
            floor(random() * 100)::INTEGER,
            floor(random() * 10 + 1)::INTEGER,
            10,
            CASE WHEN random() > 0.4 THEN true ELSE false END,
            CASE
                WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
                ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
            END,
            CASE
                WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
                ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
            END
        FROM generate_series(1, ${QUIZ_RECORDS})
        ON CONFLICT (user_id, lesson_id, attempt_number) DO NOTHING;

        RAISE NOTICE 'Generated quiz_attempts records';
    ELSE
        RAISE NOTICE 'Skipping quiz_attempts - no quiz lessons found';
    END IF;

    INSERT INTO public.user_learning_track_progress (user_id, learning_track_id, completed_at, started_at, progress_percentage, enrolled_at, next_available_date)
    SELECT
        profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
        (SELECT id FROM public.learning_tracks WHERE status = 'published' ORDER BY RANDOM() LIMIT 1),
        CASE
            WHEN random() > 0.4 THEN
                CASE
                    WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
                    ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
                END
            ELSE NULL
        END,
        CASE
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') - (random() * INTERVAL '1 day')
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') - (random() * INTERVAL '1 day')
        END,
        CASE WHEN random() > 0.4 THEN 100 ELSE floor(random() * 100)::INTEGER END,
        CASE
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') - (random() * INTERVAL '2 days')
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') - (random() * INTERVAL '2 days')
        END,
        CURRENT_DATE + (floor(random() * 7)::INTEGER || ' days')::INTERVAL
    FROM generate_series(1, ${TRACK_RECORDS})
    ON CONFLICT (user_id, learning_track_id) DO NOTHING;

    RAISE NOTICE 'Generated user_learning_track_progress records';

    INSERT INTO public.learning_track_assignments (user_id, learning_track_id, assigned_by, status, completion_required, due_date, assigned_at)
    SELECT
        profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
        (SELECT id FROM public.learning_tracks WHERE status = 'published' ORDER BY RANDOM() LIMIT 1),
        CASE WHEN random() > 0.5 THEN profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER] ELSE NULL END,
        (ARRAY['assigned', 'in_progress', 'completed', 'overdue'])[1 + floor(random() * 4)::INTEGER],
        CASE WHEN random() > 0.2 THEN true ELSE false END,
        CASE
            WHEN random() > 0.5 THEN
                CASE
                    WHEN random() > 0.6 THEN NOW() + (floor(random() * 7)::INTEGER || ' days')::INTERVAL
                    ELSE NOW() + (floor(random() * 30)::INTEGER || ' days')::INTERVAL
                END
            ELSE NULL
        END,
        CASE
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days')
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days')
        END
    FROM generate_series(1, ${ASSIGNMENT_RECORDS})
    ON CONFLICT (learning_track_id, user_id) DO NOTHING;

    RAISE NOTICE 'Generated learning_track_assignments records';

    IF quiz_lesson_count > 0 THEN
        INSERT INTO public.certificates (user_id, name, issued_by, date_acquired, status, type, org_cert, expiry_date)
        SELECT DISTINCT ON (qa.user_id, qa.lesson_id)
            qa.user_id,
            COALESCE(l.title, 'Quiz') || ' Completion Certificate',
            'RAYN Secure Pte Ltd',
            COALESCE(qa.completed_at, qa.created_at),
            'Valid',
            'Quiz Completion',
            false,
            (COALESCE(qa.completed_at, qa.created_at)::timestamp + INTERVAL '1 year')::timestamptz
        FROM public.quiz_attempts qa
        INNER JOIN public.lessons l ON qa.lesson_id = l.id
        WHERE qa.passed = true
          AND qa.completed_at IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.certificates c
              WHERE c.user_id = qa.user_id
                AND c.name = COALESCE(l.title, 'Quiz') || ' Completion Certificate'
          )
        ORDER BY qa.user_id, qa.lesson_id, qa.completed_at DESC;

        RAISE NOTICE 'Generated certificates (trophies) for passed quiz attempts';
    ELSE
        RAISE NOTICE 'Skipping certificates - no quiz lessons found';
    END IF;

    INSERT INTO public.certificates (user_id, name, issued_by, date_acquired, status, type, org_cert, expiry_date)
    SELECT DISTINCT ON (ultp.user_id, ultp.learning_track_id)
        ultp.user_id,
        COALESCE(lt.title, 'Learning Track') || ' Completion Certificate',
        'RAYN Secure Pte Ltd',
        ultp.completed_at,
        'Valid',
        'Learning Track Completion',
        false,
        (ultp.completed_at::timestamp + INTERVAL '1 year')::timestamptz
    FROM public.user_learning_track_progress ultp
    INNER JOIN public.learning_tracks lt ON ultp.learning_track_id = lt.id
    WHERE ultp.completed_at IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM public.certificates c
          WHERE c.user_id = ultp.user_id
            AND c.name = COALESCE(lt.title, 'Learning Track') || ' Completion Certificate'
            AND c.type = 'Learning Track Completion'
      )
    ORDER BY ultp.user_id, ultp.learning_track_id, ultp.completed_at DESC;

    GET DIAGNOSTICS certificate_count = ROW_COUNT;
    RAISE NOTICE 'Generated % certificates for completed learning tracks', certificate_count;

    RAISE NOTICE 'Generated analytics data successfully using % profile IDs', array_length(profile_ids, 1);
END \$\$;
EOF

    echo ""
    echo -e "${GREEN}Generating analytics data...${NC}"
    if ! psql "${CONNECTION_STRING}" --file "${SQL_FILE}"; then
        echo -e "${RED}Error generating analytics data on ${PROJECT_REF}${NC}"
        rm -f "${SQL_FILE}"
        FAILED+=("${PROJECT_REF}")
        continue
    fi
    rm -f "${SQL_FILE}"

    echo ""
    echo -e "${GREEN}✓ Analytics data generated successfully for ${PROJECT_REF}!${NC}"
    echo ""
    echo -e "${YELLOW}Final row counts:${NC}"
    psql "${CONNECTION_STRING}" -t -c "
SELECT 'user_lesson_progress: ' || COUNT(*) FROM public.user_lesson_progress
UNION ALL
SELECT 'user_behavior_analytics: ' || COUNT(*) FROM public.user_behavior_analytics
UNION ALL
SELECT 'quiz_attempts: ' || COUNT(*) FROM public.quiz_attempts
UNION ALL
SELECT 'user_learning_track_progress: ' || COUNT(*) FROM public.user_learning_track_progress
UNION ALL
SELECT 'learning_track_assignments: ' || COUNT(*) FROM public.learning_track_assignments
UNION ALL
SELECT 'certificates (quiz): ' || COUNT(*) FROM public.certificates WHERE type = 'Quiz Completion'
UNION ALL
SELECT 'certificates (track): ' || COUNT(*) FROM public.certificates WHERE type = 'Learning Track Completion'
UNION ALL
SELECT 'certificates (total): ' || COUNT(*) FROM public.certificates WHERE type IN ('Quiz Completion', 'Learning Track Completion');
" 2>&1 | while read -r line; do
        if [ -n "$line" ]; then
            echo "  $line"
        fi
    done

    echo ""
    echo -e "${YELLOW}Note: FK constraints to auth.users were dropped and not recreated.${NC}"
    echo -e "${YELLOW}      Rows sample user_id from preferred pool (five listed IDs + others to max 9) when present.${NC}"
done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    echo -e "${RED}✗ Failed (${#FAILED[@]}): ${FAILED[*]}${NC}"
    exit 1
fi

echo -e "${GREEN}All targets completed.${NC}"
