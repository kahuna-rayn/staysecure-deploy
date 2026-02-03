# Client Onboarding Checklist

## Current Manual Process

When creating a new client database, you currently need to:

1. **Create Supabase Project** in the desired region
2. **Apply Database Schema**:
   - `01_tables.sql` - Tables
   - `02_functions.sql` - Functions  
   - `03_data.sql` - Seed data
   - `04_rls_policies.sql` - RLS policies
   - `05_foreign_keys.sql` - Foreign keys
   - `06_primary_keys.sql` - Primary keys
   - `07_triggers.sql` - Triggers

3. **Configure Edge Function Secrets** (MANUAL - THIS IS THE PROBLEM):
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `SUPABASE_DB_URL`
   - `GOOGLE_TRANSLATE_API_KEY`
   - `DEEPL_API_KEY`
   - `SES_FROM_EMAIL`
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_REGION`
   - `AWS_SES_FROM_EMAIL`
   - `AUTH_LAMBDA_URL` ← **CRITICAL FOR EMAILS**
   - `APP_BASE_URL`

4. **Deploy Edge Functions** to the new project
5. **Test** user creation, deletion, email sending

## Proposed Solutions

### **Option 1: Centralized Lambda Function (IMPLEMENTED)**
- Single Lambda function shared across all clients
- Clients reference the same `AUTH_LAMBDA_URL`
- Lambda receives `client_id` parameter to route/configure appropriately
- **Pros**: Single configuration, easier maintenance
- **Cons**: Need to ensure proper client isolation in Lambda

### Option 2: Supabase CLI for Automation
- Create an onboarding script that:
  - Creates Supabase project
  - Applies all SQL files in order
  - Sets all environment variables via CLI
  - Deploys Edge Functions
- **Pros**: Fully automated
- **Cons**: Need to maintain list of secrets

### Option 3: AWS Systems Manager Parameter Store
- Store shared secrets in AWS SSM
- Each client's Lambda retrieves from SSM using its credentials
- **Pros**: Centralized, secure, versioned
- **Cons**: Requires AWS setup

### Option 4: Environment Template
- Create a `secrets.template.env` file
- Copy and fill in for each client
- Use Supabase CLI to bulk import
- **Pros**: Simple, reduces errors
- **Cons**: Still manual

## **Automated Solution (IMPLEMENTED)**

### Quick Start

1. **Set up environment variables** (one-time):
```bash
cd /Users/naresh/staysecure-projects/deploy
cp env-template.sh.example .env.local
# Edit .env.local with your actual values (see env-template.sh.example for details)
# IMPORTANT: .env.local is in .gitignore and will NOT be committed
```

2. **Create database backup** (one-time, from working database):
```bash
chmod +x scripts/create-backup.sh
./scripts/create-backup.sh cleqfnrbiqpxpzxkatda
# This creates backups/schema.sql, backups/data.sql, backups/roles.sql
```

3. **Onboard a new client**:
```bash
chmod +x scripts/onboard-client.sh
./scripts/onboard-client.sh prod "client-name" "client-domain.com"
```

That's it! The script will:
- Create Supabase project
- Configure auth settings (Site URL and Redirect URLs)
- Apply all schema files
- Set all environment variables
- Deploy Edge Functions

### For Multiple Environments

```bash
# Dev environment
./scripts/onboard-client.sh dev "client-name" "client-dev.raynsecure.com"

# Staging environment  
./scripts/onboard-client.sh staging "client-name" "client-staging.raynsecure.com"

# Production environment
./scripts/onboard-client.sh prod "client-name" "client.raynsecure.com"
```

### Manual Steps Still Required

After running the script, you still need to:
1. Update Vercel environment variables (if using custom domain)
2. Test user creation and email sending
3. Configure DNS for custom domain (if applicable)

### Environment Variables Setup

The `onboard-client.sh` script requires several environment variables. These are loaded from:
- `.env.local` (preferred, highest priority)
- `.env` (fallback)

**Setup Steps:**
1. Copy the template: `cp env-template.sh.example .env.local`
2. Edit `.env.local` with your actual values:
   - `PGPASSWORD`: Database password (set during project creation)
   - `SUPABASE_ORG_ID`: From Supabase Dashboard → Organization Settings
   - `SUPABASE_SERVICE_ROLE_KEY`: From any Supabase project → Settings → API
   - `GOOGLE_TRANSLATE_API_KEY`: From Google Cloud Console
   - `DEEPL_API_KEY`: From DeepL API Dashboard
   - `AUTH_LAMBDA_URL`: From AWS Lambda Function URL
   - `MASTER_PROJECT_REF`: Master database project ref (for sync functionality)
     - Get from: Supabase Dashboard URL → `https://app.supabase.com/project/{project_ref}`
     - Or from: Supabase API URL → `https://{project_ref}.supabase.co`

3. Source the file: `source .env.local`
4. Run onboarding: `./scripts/onboard-client.sh prod client-name`

**Note:** Both `.env.local` and `.env` are in `.gitignore` and will NOT be committed.

### Benefits

- **Same Lambda**: All clients use the same Lambda function
- **Automated**: No manual secret configuration
- **Consistent**: Same setup process for all clients
- **Scalable**: Works for dev, staging, prod, and any number of clients

