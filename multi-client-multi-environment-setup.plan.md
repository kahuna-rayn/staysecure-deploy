<!-- a7132de2-acb8-4740-91ac-2997cb129b51 ecb7b451-8587-4517-b1ad-09098d4c4fe4 -->
# Multi-Client Multi-Environment Deployment Strategy

## Architecture Overview

**Three Environments, Multi-Client Production**:

- **Dev Environment**: Keep existing deployment untouched (`cleqfnrbiqpxpzxkatda`) - stable development environment
- **Staging Environment**: Future - separate Vercel deployment + single Supabase instance for staging/QA
- **Production Environment**: Single Vercel deployment serving ALL clients via path-based routing (`staysecure-learn.raynsecure.com/rayn`, `/client1`, `/client2`, etc.). Each production client connects to their own dedicated Supabase instance determined at runtime.

## Implementation Phase

**Phase 1: RAYN Production Instance** (Current Focus)

- Create new Supabase project for RAYN demo/production
- Deploy new Vercel production project with multi-client routing
- Test with path: `staysecure-learn.raynsecure.com/rayn`
- Restore full data including existing users
- Once stable, this becomes the blueprint for all client onboarding

**Phase 2: Leave Dev Environment** (No Action)

- Current dev environment remains as-is for stable development

**Phase 3: Add Real Clients** (Future)

- Use same process to onboard actual paying clients with seed data only

## Key Components

### 1. Client Configuration Service

Create a centralized configuration mapping service that maps client paths to their Supabase credentials:

**File**: `src/config/clients.ts`

```typescript
export interface ClientConfig {
  clientId: string;
  supabaseUrl: string;
  supabaseAnonKey: string;
  displayName: string;
}

// This will be populated from environment variables or a remote config service
export const CLIENT_CONFIGS: Record<string, ClientConfig> = {
  'client1': {
    clientId: 'client1',
    supabaseUrl: 'https://xxx.supabase.co',
    supabaseAnonKey: 'eyJ...',
    displayName: 'Client One'
  },
  // ... more clients
};
```

### 2. Dynamic Supabase Client

Modify `src/integrations/supabase/client.ts` to create Supabase clients dynamically based on the current URL path:

```typescript
// Extract client ID from URL path
const getClientIdFromPath = () => {
  const path = window.location.pathname;
  const match = path.match(/^\/([^\/]+)/);
  return match ? match[1] : 'default';
};

// Create client dynamically
export const createSupabaseClient = (clientId: string) => {
  const config = CLIENT_CONFIGS[clientId];
  if (!config) throw new Error(`Unknown client: ${clientId}`);
  
  return createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { storage: localStorage, persistSession: true, autoRefreshToken: true }
  });
};

export const supabase = createSupabaseClient(getClientIdFromPath());
```

### 3. Environment Structure

**Three Vercel Projects** (matching cost structure):

- `staysecure-learn-dev` → `dev.staysecure-learn.raynsecure.com`
- `staysecure-learn-staging` → `staging.staysecure-learn.raynsecure.com`
- `staysecure-learn-prod` → `staysecure-learn.raynsecure.com`

Each Vercel project has environment variables containing JSON-encoded client configurations:

```bash
# In Vercel environment variables
VITE_CLIENT_CONFIGS='{"client1":{"supabaseUrl":"...","supabaseAnonKey":"..."},"client2":{...}}'
```

### 4. Backup and Restore Strategy

**Location**: `staysecure-hub/deploy/` (all deployment-related files)

**Two Types of Backups**:

1. **Seed Data Backup** (for new clients - default):

   - Schema: All tables, indexes, functions, triggers, RLS policies
   - Data: Only reference/content tables (lessons, lesson_tracks, dbimt, languages, etc.)
   - Excludes: User data, profiles, inventory, client-specific operational data

2. **Full Data Backup** (for internal/demo database):

   - Schema: All tables, indexes, functions, triggers, RLS policies
   - Data: Everything including users, profiles, and all operational data

**Backup Commands**:

```bash
cd ~/staysecure-hub/deploy

# For seed data (new clients)
./scripts/create-backup.sh cleqfnrbiqpxpzxkatda seed
# Creates: backups/schema.sql, backups/seed-data.sql

# For full data (internal/demo)
./scripts/create-backup.sh cleqfnrbiqpxpzxkatda full
# Creates: backups/schema.sql, backups/full-data.sql
```

**Onboarding Script Updates**:

Update `staysecure-hub/deploy/scripts/onboard-client.sh` to accept data type:

```bash
# New client with seed data (default)
./onboard-client.sh prod client-name staysecure-learn.raynsecure.com/client-name seed

# Internal/demo with full data
./onboard-client.sh prod demo staysecure-learn.raynsecure.com/demo full
```

Script actions:

1. Create Supabase project for the client
2. Restore schema.sql
3. Restore seed-data.sql OR full-data.sql based on parameter
4. Deploy edge functions with environment-specific secrets
5. Output client configuration JSON for Vercel environment variables

**Note on Authentication**: When migrating internal/demo database with full user data, existing users can login with same credentials but will need to re-authenticate once due to different JWT secrets between Supabase projects.

**New output format** (add to existing script):

```bash
# Get anon key from Supabase
ANON_KEY=$(supabase projects api-keys --project-ref ${PROJECT_REF} | grep 'anon key' | awk '{print $3}')

echo ""
echo "=== CLIENT CONFIGURATION FOR VERCEL ==="
echo "Add this to your Vercel VITE_CLIENT_CONFIGS environment variable:"
echo ""
echo "\"${CLIENT_NAME}\": {\"clientId\":\"${CLIENT_NAME}\",\"supabaseUrl\":\"https://${PROJECT_REF}.supabase.co\",\"supabaseAnonKey\":\"${ANON_KEY}\",\"displayName\":\"${CLIENT_NAME}\"}"
echo ""
```

### 5. Routing Strategy

Update `vercel.json` to support path-based client routing:

```json
{
  "rewrites": [
    { "source": "/:client/(.*)", "destination": "/index.html" },
    { "source": "/:client", "destination": "/index.html" }
  ]
}
```

Update React Router to extract and use client ID:

```typescript
// In App.tsx
const ClientRouter = () => {
  const location = useLocation();
  const clientId = location.pathname.split('/')[1];
  
  return (
    <Routes>
      <Route path="/:client" element={<Index />} />
      <Route path="/:client/admin" element={<Admin />} />
      {/* ... other routes with :client prefix */}
    </Routes>
  );
};
```

### 6. Secrets Management

**Structure** (in `staysecure-learn/secrets/`):

- `shared-secrets.env` - Shared AWS, translation API keys
- `dev-secrets.env` - Dev environment client configs
- `staging-secrets.env` - Staging environment client configs
- `prod-secrets.env` - Prod environment client configs

### 7. Deployment Workflow

**For new client onboarding**:

1. Run `staysecure-hub/scripts/onboard-client.sh prod client-name client-name.raynsecure.com`
2. Script outputs client configuration JSON
3. Add JSON to Vercel environment variable `VITE_CLIENT_CONFIGS`
4. Redeploy Vercel project (automatic or manual trigger)

**For environment setup** (dev/staging/prod):

1. Create three Vercel projects
2. Configure each with appropriate `VITE_CLIENT_CONFIGS`
3. Set up branch-based deployments: `dev` → dev project, `staging` → staging project, `main` → prod project

## Implementation Files

### New Files

- `src/config/clients.ts` - Client configuration mapping
- `src/hooks/useClient.ts` - Hook to get current client context
- `secrets/dev-secrets.env` - Dev environment secrets
- `secrets/staging-secrets.env` - Staging environment secrets

### Modified Files

- `src/integrations/supabase/client.ts` - Dynamic client creation
- `src/App.tsx` - Client-aware routing
- `vercel.json` - Path-based rewrites
- `staysecure-hub/scripts/onboard-client.sh` - Output client config JSON
- `DEPLOYMENT.md` - Updated deployment instructions

## Benefits

1. **Single Codebase**: One application serves all clients
2. **Client Isolation**: Each client has their own Supabase instance
3. **Scalable**: Add new clients by updating environment variables
4. **Environment Separation**: Dev/staging/prod clearly separated
5. **Cost Effective**: Matches agreed 3-project Vercel structure
6. **No Rebuilds**: Adding clients doesn't require code changes or rebuilds

### To-dos

- [ ] Create client configuration service (src/config/clients.ts) with ClientConfig interface and mapping
- [ ] Modify src/integrations/supabase/client.ts to create Supabase clients dynamically based on URL path
- [ ] Create useClient hook to provide current client context throughout the app
- [ ] Update App.tsx and React Router to support :client path parameter in all routes
- [ ] Update vercel.json with path-based rewrites for client routing
- [ ] Create dev-secrets.env and staging-secrets.env templates in secrets/ directory
- [ ] Update staysecure-hub/scripts/onboard-client.sh to output client config JSON for Vercel
- [ ] Update DEPLOYMENT.md with multi-client, multi-environment deployment instructions

## Post-Phase 1 Tasks

### Organisation Module Refactoring

After Phase 1 (RAYN Production Instance) is stable and working, refactor the organisation module to be truly standalone:

- [ ] **Move hooks into the module**: Move `useUserManagement`, `useUserProfiles`, `useUserRole`, etc. from `src/hooks/` into `src/modules/organisation/hooks/`
- [ ] **Make module self-contained**: Ensure organisation module has its own state management and doesn't depend on external hooks
- [ ] **Create proper exports**: Update module exports to include all necessary hooks and components for cross-app usage
- [ ] **Update consuming apps**: Modify `staysecure-hub/organisation` and `staysecure-hub/hub` to import from the module instead of local hooks
- [ ] **Test cross-app compatibility**: Verify that the refactored module works correctly in both hub applications
- [ ] **Update documentation**: Document the new module structure and usage patterns

**Rationale**: The organisation module refactoring will be much cleaner once Phase 1 establishes the multi-client architecture foundation, providing a clear pattern for how modules should be structured and consumed across different client deployments.
