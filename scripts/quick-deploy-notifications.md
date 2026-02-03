# Quick Deploy Options for Notifications Module

## Option 1: Manual Git Operations (Fastest for Testing)

### For Module Changes Only:

```bash
# 1. In notifications module
cd notifications
git add .
git commit -m "Fix RecentEmailNotifications to use username field"
git push origin main

# 2. In learn app (dev branch)
cd ../learn
git checkout dev
git pull origin dev  # Get latest
npm install  # Updates staysecure-notifications from git
git add package.json package-lock.json
git commit -m "Update staysecure-notifications module"
git push origin dev
```

**Time: ~30 seconds** vs deploy script's ~2-3 minutes

### For Quick Local Testing (No Git Push):

```bash
# In notifications module
cd notifications
npm run build  # Just build locally

# In learn app, use local path temporarily
cd ../learn
# Option A: Use npm link (symlinks local module)
cd ../notifications
npm link
cd ../learn
npm link staysecure-notifications

# Option B: Modify package.json temporarily to use file: path
# "staysecure-notifications": "file:../notifications"
npm install
```

## Option 2: Deploy Script (Production-Ready)

**When to use:**
- Deploying to production/staging
- Need clean builds (no stale artifacts)
- Want automatic verification (commit hash matching)
- Need to update multiple consuming apps
- Want tests to run automatically

**When NOT to use:**
- Quick iteration during development
- Just testing changes locally
- Already confident about the changes

## Recommendation

**For development/quick fixes:** Use manual git commands
**For production deployment:** Use deploy script for safety

## Quick Deploy Script (Simplified Version)

If you want something in-between, here's a simplified script:

```bash
#!/bin/bash
# Quick deploy - no cleanup, just commit and push
MODULE=$1
APP=$2
MSG=$3

cd $MODULE && git add . && git commit -m "$MSG" && git push origin main
cd ../$APP && git checkout dev && git pull && npm install && git add package*.json && git commit -m "Update $MODULE" && git push origin dev
```

