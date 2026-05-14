#!/bin/bash

# Create Database Backup Script
# Generates backup files under deploy/backups/ by default (same path onboard-client
# uses), regardless of the current working directory. Optional second arg overrides output dir.
# Defaults to STAGING_REF (source of truth for new client dumps).

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Same directory onboard-client.sh reads (BACKUPS_DIR) — independent of shell cwd.
DEFAULT_BACKUPS_DIR="${DEPLOY_DIR}/backups"

# Load project refs (DEV_REF, STAGING_REF, MASTER_REF, PRODUCTION_CLIENT_REFS)
PROJECTS_CONF="${SCRIPT_DIR}/../../learn/secrets/projects.conf"
if [ -f "${PROJECTS_CONF}" ]; then
    source "${PROJECTS_CONF}"
else
    echo -e "${YELLOW}Warning: projects.conf not found at ${PROJECTS_CONF}${NC}"
fi

# Default to staging — staging is the source of truth for new client dumps.
PROJECT_REF=${1:-"${STAGING_REF}"}
# Optional override; default is always deploy/backups (matches onboard-client).
OUTPUT_DIR=${2:-"${DEFAULT_BACKUPS_DIR}"}

if [ -z "$PROJECT_REF" ]; then
    echo -e "${RED}Error: No project reference and STAGING_REF is not set in projects.conf${NC}"
    echo "Usage: ./create-backup.sh [project-ref] [output-dir]"
    echo "  project-ref defaults to STAGING_REF from projects.conf"
    echo "  output-dir defaults to ${DEFAULT_BACKUPS_DIR} (onboard-client restore path)"
    echo ""
    echo "Environment Variables:"
    echo "  PGPASSWORD - Database password (optional, will prompt if not set)"
    exit 1
fi

echo -e "${GREEN}Creating backup for project: ${PROJECT_REF}${NC}"
if [ "${PROJECT_REF}" = "${STAGING_REF}" ]; then
    echo -e "${GREEN}  (staging — source of truth for new client dumps)${NC}"
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"
echo -e "${GREEN}Writing dumps to: ${OUTPUT_DIR}${NC}"

# Get database password from environment variable or prompt
if [ -z "$PGPASSWORD" ]; then
    echo "Enter database password for ${PROJECT_REF}:"
    read -s DB_PASSWORD
    export PGPASSWORD="$DB_PASSWORD"
else
    echo "Using database password from PGPASSWORD environment variable"
fi

# Build connection URL. Try direct hostname first; fall back to session-mode pooler.
# Direct:  db.<ref>.supabase.co port 6543  (works when IPv6 routing is available)
# Pooler:  aws-1-ap-southeast-1.pooler.supabase.com port 5432 (works over IPv4, username needs .<ref> suffix)
DB_HOSTNAME="db.${PROJECT_REF}.supabase.co"
POOLER_HOST="${POOLER_HOST:-aws-1-${REGION:-ap-southeast-1}.pooler.supabase.com}"

# Detect whether direct connection is reachable (IPv6 routing test)
RESOLVED_ADDR=$(dig AAAA +short "${DB_HOSTNAME}" 2>/dev/null | grep -v "^\." | head -1)
if [ -n "$RESOLVED_ADDR" ] && ping6 -c 1 -W 2 "${RESOLVED_ADDR}" &>/dev/null; then
    # Direct IPv6 available — use it (PGHOSTADDR bypasses getaddrinfo, --host provides TLS SNI)
    export PGHOSTADDR="${RESOLVED_ADDR}"
    PG_HOST="${DB_HOSTNAME}"
    PG_PORT=6543
    PG_USER="postgres"
    echo -e "${GREEN}Using direct connection (IPv6): ${RESOLVED_ADDR}${NC}"
else
    # Fall back to session-mode pooler over IPv4
    PG_HOST="${POOLER_HOST}"
    PG_PORT=5432
    PG_USER="postgres.${PROJECT_REF}"
    echo -e "${YELLOW}Direct connection unavailable — using pooler: ${POOLER_HOST}${NC}"
fi

CONNECTION_STRING="postgresql://${PG_USER}@${PG_HOST}:${PG_PORT}/postgres?sslmode=require"

pg_dump_cmd() {
    pg_dump "${CONNECTION_STRING}" "$@"
}

echo -e "${GREEN}Creating schema backup (custom format, public schema)...${NC}"
pg_dump_cmd \
    --schema-only \
    --schema=public \
    --format=custom \
    --no-owner \
    --file "${OUTPUT_DIR}/schema.dump" \
    --verbose

# Create storage schema backup if it exists
echo -e "${GREEN}Creating storage schema backup (if available)...${NC}"
pg_dump_cmd \
    --schema-only \
    --schema=storage \
    --format=custom \
    --no-owner \
    --file "${OUTPUT_DIR}/storage.dump" \
    --verbose 2>&1 || echo -e "${YELLOW}Note: Storage schema not found or empty (this is OK)${NC}"

echo -e "${GREEN}Creating demo data backup (custom format)...${NC}"
pg_dump_cmd \
    --data-only \
    --schema=public \
    --format=custom \
    --no-owner \
    --file "${OUTPUT_DIR}/demo.dump" \
    --verbose

# Create auth.users dump for demo data (needed for foreign key constraints)
echo -e "${GREEN}Creating auth.users backup for demo data (custom format)...${NC}"
pg_dump_cmd \
    --data-only \
    --table=auth.users \
    --format=custom \
    --no-owner \
    --file "${OUTPUT_DIR}/auth.dump" \
    --verbose 2>&1 || echo -e "${YELLOW}Note: Could not dump auth.users (may not be accessible)${NC}"

echo -e "${GREEN}✓ Backup files created in ${OUTPUT_DIR}/${NC}"
echo "Files:"
echo "  - ${OUTPUT_DIR}/schema.dump (custom format)"
if [ -f "${OUTPUT_DIR}/storage.dump" ]; then
    echo "  - ${OUTPUT_DIR}/storage.dump (custom format)"
fi
echo "  - ${OUTPUT_DIR}/demo.dump (custom format, demo data)"
if [ -f "${OUTPUT_DIR}/auth.dump" ]; then
    echo "  - ${OUTPUT_DIR}/auth.dump (custom format, auth.users for demo data)"
fi

# Automatically extract seed data from demo.dump
if [ -f "${OUTPUT_DIR}/demo.dump" ]; then
    echo ""
    echo -e "${GREEN}Extracting seed data from demo.dump...${NC}"
    if [ -f "${SCRIPT_DIR}/extract-seed-data.sh" ]; then
        # Call extract-seed-data.sh with the same PROJECT_REF and OUTPUT_DIR
        "${SCRIPT_DIR}/extract-seed-data.sh" "${OUTPUT_DIR}/demo.dump" "${OUTPUT_DIR}" "${PROJECT_REF}" || {
            echo -e "${YELLOW}Warning: Seed data extraction failed or skipped${NC}"
            echo -e "${YELLOW}         You can run it manually: ./scripts/extract-seed-data.sh ${OUTPUT_DIR}/demo.dump ${OUTPUT_DIR} ${PROJECT_REF}${NC}"
        }
    else
        echo -e "${YELLOW}Warning: extract-seed-data.sh not found, skipping seed data extraction${NC}"
    fi
fi

echo ""
echo -e "${GREEN}✓ Backup process complete!${NC}"