#!/bin/bash

# Generate PDF certificates for all existing certificate records that don't have one yet.
# Also backfills certificate rows for learning track completions that have no cert row yet.
#
# Usage:
#   ./scripts/generate-missing-certificates.sh <project-ref> [project-ref2] ...
#
# Example:
#   ./scripts/generate-missing-certificates.sh utzsjrqennxlajwahecs cleqfnrbiqpxpzxkatda
#
# Requires:
#   SUPABASE_SERVICE_ROLE_KEY  - for DB queries via REST API
#   SUPABASE_JWT               - user JWT for invoking the Edge Function
#
# Get service role key from: Supabase dashboard → Project Settings → API
# Get JWT from browser devtools: Application → Local Storage → find access_token

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    echo -e "${RED}Error: SUPABASE_SERVICE_ROLE_KEY is not set${NC}"
    echo "export SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>"
    exit 1
fi

if [ -z "$SUPABASE_JWT" ]; then
    echo -e "${RED}Error: SUPABASE_JWT is not set${NC}"
    echo "export SUPABASE_JWT=<your-user-jwt-from-browser>"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: At least one project reference is required${NC}"
    echo "Usage: ./scripts/generate-missing-certificates.sh <project-ref> [project-ref2] ..."
    echo "Example: ./scripts/generate-missing-certificates.sh utzsjrqennxlajwahecs"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required. Install with: brew install jq${NC}"
    exit 1
fi

TOTAL_SUCCESS=0
TOTAL_FAILED=0

for PROJECT_REF in "$@"; do
    PROJECT_URL="https://${PROJECT_REF}.supabase.co"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Processing project: ${PROJECT_REF}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1: Backfill certificate rows for completed learning tracks
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}Step 1: Checking for completed learning tracks without certificate rows...${NC}"

    COMPLETED_TRACKS=$(curl -s \
        "${PROJECT_URL}/rest/v1/user_learning_track_progress?completed_at=not.is.null&select=user_id,learning_track_id,completed_at,learning_tracks(title)" \
        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
        -H "apikey: $SUPABASE_SERVICE_ROLE_KEY")

    if echo "$COMPLETED_TRACKS" | jq -e 'type == "object"' > /dev/null 2>&1; then
        echo -e "${YELLOW}  Could not fetch learning track completions: $(echo "$COMPLETED_TRACKS" | jq -r '.message // .error // "unknown error"')${NC}"
        echo -e "${YELLOW}  Skipping backfill step.${NC}"
    else
        EXISTING_TRACK_CERTS=$(curl -s \
            "${PROJECT_URL}/rest/v1/certificates?type=eq.Learning+Track+Completion&select=user_id,name" \
            -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
            -H "apikey: $SUPABASE_SERVICE_ROLE_KEY")

        BACKFILLED=0
        BACKFILL_FAILED=0

        while IFS= read -r TRACK; do
            USER_ID=$(echo "$TRACK" | jq -r '.user_id')
            TRACK_TITLE=$(echo "$TRACK" | jq -r '.learning_tracks.title // "Unknown Track"')
            COMPLETED_AT=$(echo "$TRACK" | jq -r '.completed_at')
            CERT_NAME="${TRACK_TITLE} Completion Certificate"

            # Check if a cert row already exists for this user + track
            EXISTS=$(echo "$EXISTING_TRACK_CERTS" | jq \
                --arg uid "$USER_ID" --arg name "$CERT_NAME" \
                '[.[] | select(.user_id == $uid and .name == $name)] | length')

            if [ "$EXISTS" = "0" ]; then
                # Compute expiry: increment the year component by 1
                EXPIRY_YEAR=$(( ${COMPLETED_AT:0:4} + 1 ))
                EXPIRY_DATE="${EXPIRY_YEAR}${COMPLETED_AT:4}"

                RESULT=$(curl -s -X POST \
                    "${PROJECT_URL}/rest/v1/certificates" \
                    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
                    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
                    -H "Content-Type: application/json" \
                    -H "Prefer: return=minimal" \
                    -d "{\"user_id\":\"$USER_ID\",\"name\":\"$CERT_NAME\",\"type\":\"Learning Track Completion\",\"issued_by\":\"RAYN Secure Pte Ltd\",\"date_acquired\":\"$COMPLETED_AT\",\"expiry_date\":\"$EXPIRY_DATE\",\"status\":\"Valid\",\"org_cert\":false}")

                if [ -z "$RESULT" ]; then
                    echo -e "  ${GREEN}✓ Created cert row: ${CERT_NAME} (user ${USER_ID})${NC}"
                    BACKFILLED=$((BACKFILLED + 1))
                else
                    echo -e "  ${RED}✗ Failed to create cert row for user ${USER_ID}: ${RESULT}${NC}"
                    BACKFILL_FAILED=$((BACKFILL_FAILED + 1))
                fi
            fi
        done < <(echo "$COMPLETED_TRACKS" | jq -c '.[]')

        if [ "$BACKFILLED" -gt 0 ] || [ "$BACKFILL_FAILED" -gt 0 ]; then
            echo -e "  Backfilled: ${BACKFILLED}  Failed: ${BACKFILL_FAILED}"
        else
            echo -e "  ${YELLOW}No missing certificate rows found.${NC}"
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2: Generate PDFs for all cert rows without a certificate_url
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}Step 2: Fetching certificates without PDFs...${NC}"

    CERTS=$(curl -s \
        "${PROJECT_URL}/rest/v1/certificates?select=id,name&certificate_url=is.null" \
        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
        -H "apikey: $SUPABASE_SERVICE_ROLE_KEY")

    if echo "$CERTS" | jq -e 'type == "object"' > /dev/null 2>&1; then
        echo -e "${RED}API error for ${PROJECT_REF}: $(echo "$CERTS" | jq -r '.message // .error // .code // "unknown error"')${NC}"
        echo "Raw response: $CERTS"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi

    COUNT=$(echo "$CERTS" | jq 'length')

    if [ "$COUNT" = "0" ]; then
        echo -e "${YELLOW}No certificates found without PDFs.${NC}"
        continue
    fi

    echo -e "${GREEN}Found ${COUNT} certificates to generate:${NC}"
    echo "$CERTS" | jq -r '.[] | "  - \(.id)  \(.name)"'
    echo ""

    SUCCESS=0
    FAILED=0

    while IFS= read -r CERT_ID; do
        NAME=$(echo "$CERTS" | jq -r --arg id "$CERT_ID" '.[] | select(.id == $id) | .name')
        echo -e "${GREEN}Generating: ${NAME} (${CERT_ID})${NC}"

        RESULT=$(curl -s -X POST \
            "${PROJECT_URL}/functions/v1/generate-certificate" \
            -H "Authorization: Bearer $SUPABASE_JWT" \
            -H "Content-Type: application/json" \
            -d "{\"certificate_id\": \"$CERT_ID\"}")

        if echo "$RESULT" | jq -e '.success' > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Done${NC}"
            SUCCESS=$((SUCCESS + 1))
        else
            echo -e "  ${RED}✗ Failed: $RESULT${NC}"
            FAILED=$((FAILED + 1))
        fi

        sleep 1

    done < <(echo "$CERTS" | jq -r '.[].id')

    echo ""
    echo -e "${GREEN}Project ${PROJECT_REF}: Success: ${SUCCESS}  Failed: ${FAILED}${NC}"
    TOTAL_SUCCESS=$((TOTAL_SUCCESS + SUCCESS))
    TOTAL_FAILED=$((TOTAL_FAILED + FAILED))
done

echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}All done. Total success: ${TOTAL_SUCCESS}  Total failed: ${TOTAL_FAILED}${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
