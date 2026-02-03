#!/bin/bash
# Extract schema parts using grep/awk - more reliable than complex parsing

SCHEMA_FILE="${1:-~/staysecure-hub/deploy/backups/schema.sql}"
OUTPUT_DIR="${2:-schema_parts}"

mkdir -p "$OUTPUT_DIR"

echo "Extracting schema parts from $SCHEMA_FILE..."

# Extract header (everything before first CREATE)
awk '/^CREATE/ {exit} {print}' "$SCHEMA_FILE" > "$OUTPUT_DIR/header.sql"

# Extract types
grep -A 100 "^CREATE TYPE" "$SCHEMA_FILE" | awk '/^CREATE TYPE/,/);$/' > "$OUTPUT_DIR/types.sql" 2>/dev/null || true

# Extract tables (stop at closing ); to avoid capturing ALTER TABLE statements)
# Extract from CREATE TABLE until the matching ); that closes it
awk '
/^CREATE TABLE/ {
    in_table = 1
    print
    next
}
in_table {
    print
    if (/^\);$/) {
        print ""
        in_table = 0
    }
}
' "$SCHEMA_FILE" > "$OUTPUT_DIR/tables_raw.sql" 2>/dev/null || true

# Extract functions (more complex - need to handle $$)
# This is a simplified version - may need manual cleanup
grep -A 500 "^CREATE FUNCTION\|^CREATE OR REPLACE FUNCTION" "$SCHEMA_FILE" > "$OUTPUT_DIR/functions_raw.sql" 2>/dev/null || true

# Extract triggers
grep -A 50 "^CREATE TRIGGER" "$SCHEMA_FILE" > "$OUTPUT_DIR/triggers_raw.sql" 2>/dev/null || true

# Extract RLS policies
grep -A 20 "^CREATE POLICY" "$SCHEMA_FILE" > "$OUTPUT_DIR/rls_policies_raw.sql" 2>/dev/null || true

# Extract primary keys (need to capture ALTER TABLE line before ADD CONSTRAINT)
grep -B 1 -A 2 "ADD CONSTRAINT.*PRIMARY KEY" "$SCHEMA_FILE" | grep -v "^--" > "$OUTPUT_DIR/primary_keys_raw.sql" 2>/dev/null || true

# Extract foreign keys (need to capture ALTER TABLE line before ADD CONSTRAINT)
grep -B 1 -A 10 "ADD CONSTRAINT.*FOREIGN KEY" "$SCHEMA_FILE" | grep -v "^--" > "$OUTPUT_DIR/foreign_keys_raw.sql" 2>/dev/null || true

# Extract unique constraints (need to capture ALTER TABLE line before ADD CONSTRAINT)
grep -B 1 -A 2 "ADD CONSTRAINT.*UNIQUE" "$SCHEMA_FILE" | grep -v "^--" > "$OUTPUT_DIR/unique_constraints_raw.sql" 2>/dev/null || true

# Extract indexes
grep -A 20 "^CREATE INDEX\|^CREATE UNIQUE INDEX" "$SCHEMA_FILE" > "$OUTPUT_DIR/indexes_raw.sql" 2>/dev/null || true

# Extract views
grep -A 50 "^CREATE VIEW\|^CREATE OR REPLACE VIEW" "$SCHEMA_FILE" > "$OUTPUT_DIR/views_raw.sql" 2>/dev/null || true

# Extract sequences
grep -A 20 "^CREATE SEQUENCE" "$SCHEMA_FILE" > "$OUTPUT_DIR/sequences_raw.sql" 2>/dev/null || true

# Extract enable RLS
grep "ENABLE ROW LEVEL SECURITY" "$SCHEMA_FILE" > "$OUTPUT_DIR/enable_rls.sql" 2>/dev/null || true

# Extract comments
grep "^COMMENT ON" "$SCHEMA_FILE" > "$OUTPUT_DIR/comments.sql" 2>/dev/null || true

# Extract grants
grep "^GRANT\|^REVOKE" "$SCHEMA_FILE" > "$OUTPUT_DIR/grants.sql" 2>/dev/null || true

echo "✓ Extracted raw files to $OUTPUT_DIR/"
echo "Note: Some files may need manual cleanup to handle multi-line statements properly"

