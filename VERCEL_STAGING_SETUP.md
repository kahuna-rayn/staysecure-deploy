# Vercel Staging Environment Setup

## Overview

Staging uses a **single Supabase instance** (unlike production which is multi-client). Set up branch-based deployments with separate Vercel projects.

## Step 1: Create Staging Branch

```bash
cd ~/LEARN/staysecure-learn
git checkout -b staging
git push -u origin staging
```

## Step 2: Create Vercel Staging Project

1. Go to [Vercel Dashboard](https://vercel.com/dashboard)
2. Click **Add New** → **Project**
3. Import your GitHub repository (`staysecure-learn`)
4. **Project Name**: `staysecure-learn-staging`
5. **Framework Preset**: Vite
6. **Root Directory**: `./` (or leave default)
7. **Build Command**: `npm run build`
8. **Output Directory**: `dist`

## Step 3: Configure Branch Deployment

In the Vercel project settings:

1. Go to **Settings** → **Git**
2. Under **Production Branch**, select **staging** (or create a custom branch mapping)
3. Or use **Branch-based deployments**:
   - Go to **Settings** → **Git** → **Branch Protection**
   - Enable **Auto-assign Preview Deployments**
   - Set **Production Branch** to `staging`

**Alternative**: Create a completely separate Vercel project that only deploys from `staging` branch.

## Step 4: Get Staging Project Reference and Anon Key

Run this to get your staging Supabase project details:

```bash
cd ~/staysecure-hub/deploy
supabase projects list --output json | jq '.[] | select(.name | contains("staging")) | {name, id}'
```

Then get the anon key:

```bash
supabase projects api-keys --project-ref <STAGING_PROJECT_REF> | grep anon
```

Or check the output from when you ran `onboard-client.sh` - it should have printed the configuration JSON.

## Step 5: Set Environment Variables in Vercel

In your **staging Vercel project**:

1. Go to **Settings** → **Environment Variables**
2. Click **Add New**
3. **Name**: `VITE_CLIENT_CONFIGS`
4. **Value**: (Single-line JSON, replace with your actual values)

### For Staging (Single Client):

Since staging is a single Supabase instance, you can use either:

**Option A: Single staging client**
```json
{"staging":{"clientId":"staging","supabaseUrl":"https://<STAGING_PROJECT_REF>.supabase.co","supabaseAnonKey":"<STAGING_ANON_KEY>","displayName":"Staging"},"default":{"clientId":"default","supabaseUrl":"https://<STAGING_PROJECT_REF>.supabase.co","supabaseAnonKey":"<STAGING_ANON_KEY>","displayName":"Staging"}}
```

**Option B: Just default** (simpler, since staging is single-instance)
```json
{"default":{"clientId":"default","supabaseUrl":"https://<STAGING_PROJECT_REF>.supabase.co","supabaseAnonKey":"<STAGING_ANON_KEY>","displayName":"Staging"}}
```

5. **Environment**: Select **Production** (since staging branch = production for staging project)
6. Click **Save**

## Step 6: Configure Custom Domain (Optional)

1. Go to **Settings** → **Domains**
2. Add domain: `staging.staysecure-learn.raynsecure.com`
3. Follow DNS configuration instructions

## Step 7: Configure Supabase Auth Settings

1. Go to Supabase Dashboard → Your staging project
2. Navigate to **Authentication** → **URL Configuration**
3. Set **Site URL**: `https://staging.staysecure-learn.raynsecure.com`
4. Add **Redirect URLs**:
   - `https://staging.staysecure-learn.raynsecure.com/reset-password`
   - `https://staging.staysecure-learn.raynsecure.com/activate-account`

## Step 8: Deploy

Push to staging branch:

```bash
git checkout staging
git merge main  # Or cherry-pick specific commits
git push origin staging
```

Vercel will automatically deploy when you push to the `staging` branch.

## Verification

1. Visit `https://staging.staysecure-learn.raynsecure.com` (or your Vercel preview URL)
2. Open browser console
3. Look for:
   - `Using multi-client configuration: ['staging', 'default']` (or just `['default']`)
   - `Using Supabase client for: staging` (or `default`)

## Branch Strategy Summary

- **`main` branch** → Deploys to **production** Vercel project → `staysecure-learn.raynsecure.com`
- **`staging` branch** → Deploys to **staging** Vercel project → `staging.staysecure-learn.raynsecure.com`
- **`dev` branch** (optional) → Deploys to **dev** Vercel project → `dev.staysecure-learn.raynsecure.com`

Each Vercel project has its own `VITE_CLIENT_CONFIGS` environment variable pointing to the appropriate Supabase instance(s).

