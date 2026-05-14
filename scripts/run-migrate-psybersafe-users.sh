#!/usr/bin/env bash
# Wrapper for migrate-psybersafe-users.ts — run from anywhere; loads deps/env from deploy/scripts/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVOCATION_DIR="$(pwd)"

usage() {
  sed 's/^  //' <<'EOF'
  Psybersafe → StaySecure Learn migration.

  Usage:
    ./run-migrate-psybersafe-users.sh <workbook.xlsx> <progress-sheet> [--dry-run|--migrate] [more flags...]

  Examples:
    ./run-migrate-psybersafe-users.sh "./RenCi Learn Progress 20260506.xlsx" 20260506
    ./run-migrate-psybersafe-users.sh "./report.xlsx" 20251230 --dry-run
    ./run-migrate-psybersafe-users.sh "./report.xlsx" 20251230 --migrate

  Extra flags are passed through (see migrate-psybersafe-users.ts header), e.g.:
    --business-line-col "Business Line"
    --status-sheet Status
    --score-sheet Score

  Env in deploy/scripts/.env or deploy/.env:
    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
  Also for --dry-run / --migrate:
    APP_BASE_URL
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

XLSX="$1"
PROGRESS_SHEET="$2"
shift 2

# Resolve workbook relative to where you ran the script (not deploy/scripts/).
if [[ "$XLSX" != /* ]]; then
  XLSX="${INVOCATION_DIR%/}/$XLSX"
fi

if [[ ! -f "$XLSX" ]]; then
  echo "Workbook not found (or not a file): $XLSX" >&2
  exit 1
fi

cd "$SCRIPT_DIR"
exec npx ts-node migrate-psybersafe-users.ts \
  --xlsx "$XLSX" \
  --progress-sheet "$PROGRESS_SHEET" \
  "$@"
