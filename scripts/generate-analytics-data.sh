#!/bin/bash

# Generate Analytics Demo Data Script
# Generates synthetic data for analytics tables using only existing profile IDs
# Usage: ./generate-analytics-data.sh <project-ref> [progress-records] [behavior-records] [quiz-records] [track-records]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_REF=${1:-""}
PROGRESS_RECORDS=${2:-500}
BEHAVIOR_RECORDS=${3:-1000}
QUIZ_RECORDS=${4:-300}
TRACK_RECORDS=${5:-150}
ASSIGNMENT_RECORDS=${6:-200}

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: Project reference is required${NC}"
    echo "Usage: ./generate-analytics-data.sh <project-ref> [progress-records] [behavior-records] [quiz-records] [track-records] [assignment-records]"
    echo "  project-ref: Supabase project reference ID"
    echo "  progress-records: Number of user_lesson_progress records (default: 500)"
    echo "  behavior-records: Number of user_behavior_analytics records (default: 1000)"
    echo "  quiz-records: Number of quiz_attempts records (default: 300)"
    echo "  track-records: Number of user_learning_track_progress records (default: 150)"
    echo "  assignment-records: Number of learning_track_assignments records (default: 200)"
    exit 1
fi

# Load environment variables
if [ -f ".env.local" ]; then
    source .env.local
elif [ -f "../.env.local" ]; then
    source ../.env.local
elif [ -f ".env" ]; then
    source .env
elif [ -f "../.env" ]; then
    source ../.env
fi

# Check for required environment variables
if [ -z "$PGPASSWORD" ]; then
    echo -e "${RED}Error: PGPASSWORD environment variable is required${NC}"
    exit 1
fi

CONNECTION_STRING="host=db.${PROJECT_REF}.supabase.co port=6543 user=postgres dbname=postgres sslmode=require"

echo -e "${GREEN}Generating analytics demo data for project: ${PROJECT_REF}${NC}"
echo ""

# Check available users and show them
echo -e "${YELLOW}Checking available users (profiles)...${NC}"
USER_COUNT=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM public.profiles;" 2>&1 | grep -v "ERROR" | tr -d ' \n')
echo -e "  Found ${USER_COUNT} users in profiles table"

if [ "$USER_COUNT" -eq "0" ]; then
    echo -e "${RED}Error: No users found in profiles table. Please import profiles first.${NC}"
    exit 1
fi

# Show sample users
echo -e "${YELLOW}Sample users that will be used:${NC}"
psql "${CONNECTION_STRING}" -t -c "SELECT id, full_name, username FROM public.profiles LIMIT 5;" 2>&1 | grep -v "ERROR" | while read -r line; do
    if [ -n "$line" ]; then
        echo "  $line"
    fi
done

# Check available lessons and tracks
LESSON_COUNT=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM public.lessons WHERE status = 'published';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
TRACK_COUNT=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM public.learning_tracks WHERE status = 'published';" 2>&1 | grep -v "ERROR" | tr -d ' \n')
QUIZ_LESSON_COUNT=$(psql "${CONNECTION_STRING}" -t -c "SELECT COUNT(*) FROM public.lessons WHERE status = 'published' AND lesson_type = 'quiz';" 2>&1 | grep -v "ERROR" | tr -d ' \n')

echo ""
echo -e "${YELLOW}Available content:${NC}"
echo "  - Published lessons: ${LESSON_COUNT}"
echo "  - Published learning tracks: ${TRACK_COUNT}"
echo "  - Quiz lessons: ${QUIZ_LESSON_COUNT}"

if [ "$LESSON_COUNT" -eq "0" ]; then
    echo -e "${RED}Error: No published lessons found. Please import lessons first.${NC}"
    exit 1
fi

# Temporarily drop FK constraints on analytics tables that reference auth.users
echo ""
echo -e "${YELLOW}Preparing analytics tables (dropping FK constraints to auth.users)...${NC}"
ANALYTICS_TABLES=("user_behavior_analytics" "quiz_attempts" "user_learning_track_progress" "learning_track_assignments" "certificates")

for table in "${ANALYTICS_TABLES[@]}"; do
    FK_CONSTRAINTS=$(psql "${CONNECTION_STRING}" -t -c "SELECT conname FROM pg_constraint WHERE conrelid = 'public.${table}'::regclass AND contype = 'f' AND confrelid = 'auth.users'::regclass;" 2>&1 | grep -v "ERROR" | grep -v "^$" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$FK_CONSTRAINTS" ]; then
        echo "$FK_CONSTRAINTS" | while IFS= read -r FK_CONSTRAINT; do
            FK_CONSTRAINT=$(echo "$FK_CONSTRAINT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$FK_CONSTRAINT" ] && [ "$FK_CONSTRAINT" != "" ]; then
                echo -e "  Dropping FK constraint on ${table}: ${FK_CONSTRAINT}"
                psql "${CONNECTION_STRING}" \
                    --command "ALTER TABLE public.${table} DROP CONSTRAINT IF EXISTS \"${FK_CONSTRAINT}\";" > /dev/null 2>&1
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

# Create temporary SQL file
SQL_FILE=$(mktemp)
cat > "${SQL_FILE}" <<EOF
-- Generate Analytics Demo Data
-- Uses only profile IDs from restored profiles table
DO \$\$
DECLARE
    user_count INTEGER;
    lesson_count INTEGER;
    track_count INTEGER;
    quiz_lesson_count INTEGER;
    profile_ids UUID[];
    certificate_count INTEGER;
BEGIN
    -- Get counts and IDs
    SELECT COUNT(*) INTO user_count FROM public.profiles;
    SELECT COUNT(*) INTO lesson_count FROM public.lessons WHERE status = 'published';
    SELECT COUNT(*) INTO track_count FROM public.learning_tracks WHERE status = 'published';
    SELECT COUNT(*) INTO quiz_lesson_count FROM public.lessons WHERE status = 'published' AND lesson_type = 'quiz';
    
    -- Get array of all profile IDs (these will be used as user_ids)
    SELECT ARRAY_AGG(id) INTO profile_ids FROM public.profiles;
    
    RAISE NOTICE 'Found % users (profiles), % lessons, % tracks, % quiz lessons', user_count, lesson_count, track_count, quiz_lesson_count;
    
    -- Generate user_lesson_progress (references profiles.id, so no FK issue)
    -- Note: user_lesson_progress has completed_nodes (array), not progress_percentage
    -- Generate mix of old and recent activity (40% recent within 30 days, 60% older)
    INSERT INTO public.user_lesson_progress (user_id, lesson_id, completed_at, started_at, completed_nodes, last_accessed)
    SELECT 
        profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
        (SELECT id FROM public.lessons WHERE status = 'published' ORDER BY RANDOM() LIMIT 1),
        CASE 
            WHEN random() > 0.3 THEN 
                CASE 
                    WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') -- 40% recent (last 30 days)
                    ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') -- 60% older (30-90 days)
                END
            ELSE NULL 
        END,
        CASE 
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') - (random() * INTERVAL '2 hours')
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') - (random() * INTERVAL '2 hours')
        END,
        CASE WHEN random() > 0.3 THEN ARRAY['node1', 'node2', 'node3']::text[] ELSE ARRAY[]::text[] END,
        CASE 
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '7 days') -- Recent access
            ELSE NOW() - (random() * INTERVAL '30 days') -- Older access
        END
    FROM generate_series(1, ${PROGRESS_RECORDS})
    ON CONFLICT (user_id, lesson_id) DO NOTHING;
    
    RAISE NOTICE 'Generated user_lesson_progress records';
    
    -- Generate user_behavior_analytics (FK to auth.users dropped, using profile IDs)
    -- Note: user_behavior_analytics has nodes_visited (array), not pages_visited
    -- Generate mix of old and recent activity (40% recent within 30 days, 60% older)
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
    
    -- Generate quiz_attempts (FK to auth.users dropped, using profile IDs)
    -- Note: quiz_attempts has unique constraint on (user_id, lesson_id, attempt_number)
    -- Only generate if quiz lessons exist
    -- Generate mix of old and recent activity (40% recent within 30 days, 60% older)
    IF quiz_lesson_count > 0 THEN
        INSERT INTO public.quiz_attempts (user_id, lesson_id, attempt_number, percentage_score, correct_answers, total_questions, passed, created_at, completed_at)
        SELECT 
            profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
            (SELECT id FROM public.lessons WHERE status = 'published' AND lesson_type = 'quiz' ORDER BY RANDOM() LIMIT 1),
            floor(random() * 3 + 1)::INTEGER, -- 1-3 attempts
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
    
    -- Generate user_learning_track_progress (FK to auth.users dropped, using profile IDs)
    -- Note: user_learning_track_progress has enrolled_at and next_available_date, not last_accessed_at
    -- Generate mix of old and recent activity (40% recent within 30 days, 60% older)
    INSERT INTO public.user_learning_track_progress (user_id, learning_track_id, completed_at, started_at, progress_percentage, enrolled_at, next_available_date)
    SELECT 
        profile_ids[1 + floor(random() * array_length(profile_ids, 1))::INTEGER],
        (SELECT id FROM public.learning_tracks WHERE status = 'published' ORDER BY RANDOM() LIMIT 1),
        CASE 
            WHEN random() > 0.4 THEN 
                CASE 
                    WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') -- 40% recent (last 30 days)
                    ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') -- 60% older (30-90 days)
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
    
    -- Generate learning_track_assignments (FK to auth.users dropped, using profile IDs)
    -- Status must be one of: 'assigned', 'in_progress', 'completed', 'overdue'
    -- Generate mix of old and recent activity (40% recent within 30 days, 60% older)
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
                    WHEN random() > 0.6 THEN NOW() + (floor(random() * 7)::INTEGER || ' days')::INTERVAL -- Recent future dates
                    ELSE NOW() + (floor(random() * 30)::INTEGER || ' days')::INTERVAL -- Future dates
                END
            ELSE NULL 
        END,
        CASE 
            WHEN random() > 0.6 THEN NOW() - (random() * INTERVAL '30 days') -- 40% recent
            ELSE NOW() - (INTERVAL '30 days' + random() * INTERVAL '60 days') -- 60% older
        END
    FROM generate_series(1, ${ASSIGNMENT_RECORDS})
    ON CONFLICT (learning_track_id, user_id) DO NOTHING;
    
    RAISE NOTICE 'Generated learning_track_assignments records';
    
    -- Generate certificates (trophies) for passed quiz attempts
    -- Only generate if quiz lessons exist and we have passed quiz attempts
    -- Note: certificates.user_id has FK to auth.users, which is dropped for this operation
    IF quiz_lesson_count > 0 THEN
        -- Create certificates for each unique user/lesson combination where quiz was passed
        INSERT INTO public.certificates (user_id, name, issued_by, date_acquired, status, type, org_cert, expiry_date)
        SELECT DISTINCT ON (qa.user_id, qa.lesson_id)
            qa.user_id,
            COALESCE(l.title, 'Quiz') || ' Completion Certificate',
            'RAYN Secure Pte Ltd',
            COALESCE(qa.completed_at, qa.created_at),
            'Valid',
            'Quiz Completion', -- Using 'Quiz Completion' type for quiz certificates/trophies
            false,
            (COALESCE(qa.completed_at, qa.created_at)::timestamp + INTERVAL '1 year')::timestamptz -- Default expiry: 1 year
        FROM public.quiz_attempts qa
        INNER JOIN public.lessons l ON qa.lesson_id = l.id
        WHERE qa.passed = true
          AND qa.completed_at IS NOT NULL
          AND NOT EXISTS (
              -- Avoid duplicates: only create one certificate per user/lesson combination
              SELECT 1 FROM public.certificates c
              WHERE c.user_id = qa.user_id
                AND c.name = COALESCE(l.title, 'Quiz') || ' Completion Certificate'
          )
        ORDER BY qa.user_id, qa.lesson_id, qa.completed_at DESC;
        
        RAISE NOTICE 'Generated certificates (trophies) for passed quiz attempts';
    ELSE
        RAISE NOTICE 'Skipping certificates - no quiz lessons found';
    END IF;
    
    -- Generate certificates for completed learning tracks
    INSERT INTO public.certificates (user_id, name, issued_by, date_acquired, status, type, org_cert, expiry_date)
    SELECT DISTINCT ON (ultp.user_id, ultp.learning_track_id)
        ultp.user_id,
        COALESCE(lt.title, 'Learning Track') || ' Completion Certificate',
        'RAYN Secure Pte Ltd',
        ultp.completed_at,
        'Valid',
        'Learning Track Completion',
        false,
        (ultp.completed_at::timestamp + INTERVAL '1 year')::timestamptz -- Default expiry: 1 year
    FROM public.user_learning_track_progress ultp
    INNER JOIN public.learning_tracks lt ON ultp.learning_track_id = lt.id
    WHERE ultp.completed_at IS NOT NULL
      AND NOT EXISTS (
          -- Avoid duplicates: only create one certificate per user/track combination
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

# Execute the SQL
echo ""
echo -e "${GREEN}Generating analytics data...${NC}"
psql "${CONNECTION_STRING}" --file "${SQL_FILE}" || {
    echo -e "${RED}Error generating analytics data${NC}"
    rm -f "${SQL_FILE}"
    exit 1
}

rm -f "${SQL_FILE}"

# Show final counts
echo ""
echo -e "${GREEN}✓ Analytics data generated successfully!${NC}"
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
" 2>&1 | grep -v "ERROR" | while read -r line; do
    if [ -n "$line" ]; then
        echo "  $line"
    fi
done

echo ""
echo -e "${YELLOW}Note: FK constraints to auth.users were dropped and not recreated (since auth.users doesn't exist)${NC}"
echo -e "${YELLOW}      The data will be assigned to the ${USER_COUNT} profile IDs from the restored profiles table${NC}"

