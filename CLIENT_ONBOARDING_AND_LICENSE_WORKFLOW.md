# Client Onboarding and License Management Workflow

This document outlines the complete workflow for onboarding a new client and managing their product licenses across the master database and client database.

## Overview

- **Master Database**: `oownotmpcqcgojhrzqaj` - Central database where we manage learn content, customers, and product licenses
- **Client Database**: Each client has their own Supabase project with their own database
- **License Management**: Managed in the master database (License app), synced to client databases as needed

## Workflow Summary

The complete client onboarding and license management workflow consists of 4 steps:

1. **Create Backup** (Automated) - Create a backup of the master database schema and seed data
2. **Onboard Client** (Automated) - Create a new Supabase project for the client and restore schema/seed data
3. **Create Client in License App** (Manual - Current State) - Create customer record in master DB and sync customer row to client DB
4. **Assign Product Licenses** (Manual - Current State) - Assign licenses to customer in master DB and sync license data to client DB

**Note: Steps 3 and 4 are currently manual operations. Future automation will integrate customer and license sync directly into the License app.**

## Workflow Steps

### Step 1: Create Backup (Master Database)

Create a backup of the master database schema and seed data.

**Command:**
```bash
cd /Users/naresh/staysecure-projects/deploy
./scripts/create-backup.sh <master-project-ref>
```

**What it does:**
- Creates `schema.dump` - Database schema (tables, functions, triggers, RLS policies)
- Creates `seed.dump` - Seed/reference data including:
  - `languages` - Language reference data
  - `lessons`, `lesson_nodes`, `lesson_answers` - Learning content
  - `learning_tracks`, `learning_track_lessons` - Track content
  - `lesson_translations`, `lesson_node_translations`, `lesson_answer_translations` - Translations
  - `email_layouts`, `email_templates` - Email templates
  - `template_variables`, `template_variable_translations` - Template variables
  - `products` - Product catalog (LEARN, GOVERN, etc.)
  - `breach_management_team` - Reference team structure (member FK nullified)
- Automatically runs `extract-seed-data.sh` to extract seed data from demo data

**Output:**
- `backups/schema.dump`
- `backups/seed.dump`

---

### Step 2: Onboard Client (Automated)

Create a new Supabase project for the client and restore schema and seed data.

**Command:**
```bash
cd /Users/naresh/staysecure-projects/deploy
./scripts/onboard-client.sh [prod|staging|dev] <client-name> [seed|demo] [region]
```

**Example:**
```bash
./scripts/onboard-client.sh prod rayn seed ap-southeast-1
```

**What it does:**
1. Creates new Supabase project
2. Configures auth settings (Site URL, Redirect URLs)
3. Restores schema from `backups/schema.dump`
4. Restores seed data from `backups/seed.dump` (if `seed`) or `backups/demo.dump` (if `demo`)
5. Sets Edge Function secrets (API keys, Lambda URLs, etc.)
6. Deploys Edge Functions to the new project
7. Sets client service key in master database (for sync functionality)

**Important Notes:**
- `seed` data type: Reference/template data only (no users)
- `demo` data type: Full data including users (for internal/demo use)
- The script automatically sets `CLIENT_SERVICE_KEY_{PROJECT_REF}` secret in master DB for sync operations
- **Save the `PROJECT_REF`** from the output - you'll need it in Step 3

**Output:**
- New Supabase project created
- Client database initialized with schema and seed data
- Edge Functions deployed and configured

---

### Step 3: Create Client in License App (Manual - Current State)

**⚠️ MANUAL STEP - Automation pending implementation**

Create the customer record in the License app and sync the customer row to the client database.

#### 3.1: Create Customer in License App (Master DB)

1. Open License app (master database)
2. Navigate to Customers view
3. Click "Create Customer" or similar
4. Fill in customer details:
   - **Customer Name**: Full name (e.g., "Rayn Secure")
   - **Short Name**: Unique identifier (e.g., "rayn") - used for client path routing
   - **Primary Contact**: Contact person name
   - **Email**: Contact email
   - **Supabase Project Ref**: The `PROJECT_REF` from Step 2 (e.g., `abc123xyz`)
   - **Has Learn**: Toggle if needed (legacy flag for SyncManager filtering)
   - **Is Active**: Set to `true`
5. Click "Save" or "Create Customer"

**What happens:**
- Customer row is created in master database `customers` table
- A UUID (`id`) is automatically generated for the customer

#### 3.2: Sync Customer Row to Client Database (Manual)

**⚠️ Currently requires manual database operation**

The customer row must be synced to the client database because:
- `customer_product_licenses.customer_id` has a foreign key constraint referencing `customers.id`
- The same `customer_id` UUID must exist in both databases
- License sync (Step 4) requires the customer row to exist in client DB

**Current Manual Process:**
1. Connect to client database (using service role key)
2. Insert customer row with **same UUID** from master DB:

```sql
-- Get customer data from master DB first
-- In master DB:
SELECT id, customer_name, short_name, primary_contact, email, is_active 
FROM customers 
WHERE short_name = '<client-short-name>';

-- Then in client DB (replace placeholders):
INSERT INTO customers (id, customer_name, short_name, primary_contact, email, is_active)
VALUES (
  '<uuid-from-master>',  -- MUST match master DB UUID
  '<customer-name>',
  '<short-name>',
  '<primary-contact>'::text,
  '<email>'::text,
  true
);
```

**Important:**
- The `id` (UUID) **must match** the master database UUID exactly
- `supabase_project_ref` is **not needed** in client DB (only in master)
- `has_learn` is **not needed** in client DB (only in master for SyncManager filtering)

**Future Automation:**
- Create/update customer in License app should automatically trigger sync to client DB
- Will use Edge Function similar to `sync-lesson-content` but for customer/license data
- Will use service role key stored in master DB Edge Function secrets

---

### Step 4: Assign Product Licenses (Manual - Current State)

**⚠️ MANUAL STEP - Automation pending implementation**

Assign product licenses to the customer and sync license data to the client database.

#### 4.1: Create License in License App (Master DB)

1. Open License app (master database)
2. Navigate to Licenses view
3. Click "Create License" or similar
4. Fill in license details:
   - **Customer**: Select the customer created in Step 3.1
   - **Product**: Select product (e.g., "StaySecure LEARN", "StaySecure GOVERN")
   - **Language**: Select language (e.g., "English", "Chinese (Simplified)")
   - **Seats**: Number of user seats
   - **Term**: License term in months (e.g., 12)
   - **Start Date**: License start date
   - **End Date**: Auto-calculated based on term (or set manually)
5. Click "Save" or "Create License"

**What happens:**
- License row is created in master database `customer_product_licenses` table
- A UUID (`id`) is automatically generated for the license
- `customer_id` references the customer created in Step 3
- `product_id` references the `products` table (seeded in Step 2)

#### 4.2: Sync License Data to Client Database (Manual)

**⚠️ Currently requires manual database operation**

The license data must be synced to the client database because:
- `create-user` Edge Function will query client DB's `customer_product_licenses` to determine which products the customer has licensed
- This determines whether to set `cyber_learner` (LEARN) or `dpe_learner` (GOVERN) flags when creating users

**Current Manual Process:**
1. Connect to client database (using service role key)
2. Ensure `customers` row exists (should exist from Step 3.2)
3. Ensure `products` row exists (should exist from seed data in Step 2)
4. Insert/update license row with **same UUID** from master DB:

```sql
-- Get license data from master DB first
-- In master DB:
SELECT 
  cpl.id, 
  cpl.customer_id, 
  cpl.product_id, 
  cpl.language, 
  cpl.seats, 
  cpl.term, 
  cpl.start_date, 
  cpl.end_date,
  p.name as product_name,
  c.short_name as customer_short_name
FROM customer_product_licenses cpl
JOIN products p ON p.id = cpl.product_id
JOIN customers c ON c.id = cpl.customer_id
WHERE c.short_name = '<client-short-name>';

-- Then in client DB (replace placeholders, upsert to handle updates):
INSERT INTO customer_product_licenses (
  id, 
  customer_id, 
  product_id, 
  language, 
  seats, 
  term, 
  start_date, 
  end_date
)
VALUES (
  '<license-uuid-from-master>',  -- MUST match master DB UUID
  '<customer-uuid-from-master>',  -- MUST match customer UUID from Step 3.2
  '<product-uuid>',  -- Product UUID (should match between master and client)
  '<language>',
  <seats>,
  <term>,
  '<start-date>'::timestamptz,
  '<end-date>'::timestamptz
)
ON CONFLICT (id) DO UPDATE
SET 
  customer_id = EXCLUDED.customer_id,
  product_id = EXCLUDED.product_id,
  language = EXCLUDED.language,
  seats = EXCLUDED.seats,
  term = EXCLUDED.term,
  start_date = EXCLUDED.start_date,
  end_date = EXCLUDED.end_date;
```

**Important:**
- The `id` (UUID) **must match** the master database UUID exactly
- The `customer_id` **must match** the customer UUID synced in Step 3.2
- The `product_id` **must match** the product UUID (same in master and client since seeded)
- Use `ON CONFLICT` to handle updates (upsert pattern)

**Future Automation:**
- Create/update license in License app should automatically trigger sync to client DB
- Will use Edge Function to:
  1. Ensure `customers` row exists in client DB (create if missing)
  2. Upsert `customer_product_licenses` rows to client DB
  3. Handle deletions (remove licenses from client DB when removed in master)

---

## Data Flow Summary

### Master Database (`oownotmpcqcgojhrzqaj`)
- **Source of Truth** for:
  - Customer information (`customers` table)
  - Product licenses (`customer_product_licenses` table)
  - Learn content (lessons, tracks, translations)

### Client Database (Each client's Supabase project)
- **Contains**:
  - Single customer row (`customers` table) - synced from master
  - License rows (`customer_product_licenses` table) - synced from master
  - Products (`products` table) - seeded once during onboarding
  - Learn content - synced from master via SyncManager

### Key Requirements

1. **UUID Matching**: 
   - Customer `id` must match between master and client DB
   - License `id` must match between master and client DB
   - `customer_id` in licenses must match customer `id` in client DB

2. **Foreign Key Constraints**:
   - `customer_product_licenses.customer_id` → `customers.id` (must exist in client DB)
   - `customer_product_licenses.product_id` → `products.id` (exists from seed data)

3. **Data Integrity**:
   - Always sync `customers` row before `customer_product_licenses` rows
   - Use upsert patterns to handle updates

---

## Future Automation (Pending Implementation)

### Automated Customer Sync
- **Trigger**: Create/update customer in License app
- **Action**: Automatically sync customer row to client database
- **Edge Function**: `sync-customer-data` (to be created)
- **Uses**: Service role key stored in master DB Edge Function secrets

### Automated License Sync
- **Trigger**: Create/update/delete license in License app
- **Action**: Automatically sync license rows to client database
- **Edge Function**: `sync-license-data` (to be created)
- **Uses**: Service role key stored in master DB Edge Function secrets
- **Handles**: 
  - Ensures customer row exists (creates if missing)
  - Upserts license rows
  - Handles deletions

### User Creation Integration
- **When**: User is created via `create-user` Edge Function
- **Action**: Query client DB's `customer_product_licenses` to determine licensed products
- **Sets**: 
  - `cyber_learner: true` if customer has LEARN product (`2f669069-de0a-4d4a-8823-1f85caf484bd`)
  - `dpe_learner: true` if customer has GOVERN product (`f942f936-50ae-4339-9896-90325e7a2777`)
  - Both flags if customer has both products

---

## Product IDs (Reference)

- **StaySecure LEARN**: `2f669069-de0a-4d4a-8823-1f85caf484bd`
- **StaySecure GOVERN**: `f942f936-50ae-4339-9896-90325e7a2777`

These are seeded in Step 2 and should be the same in both master and client databases.

---

## Related Documentation

- [CLIENT_ONBOARDING.md](./CLIENT_ONBOARDING.md) - Technical onboarding process
- [SYNC_LESSON_CONTENT_README.md](../learn/docs/features/completed/SYNC_LESSON_CONTENT_README.md) - Learn content sync mechanism
