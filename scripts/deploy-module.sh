#!/bin/bash
# Comprehensive module deployment script
# Handles: clean build, commit, push module(s) → update consuming apps → commit, push apps
# Usage: ./deploy/scripts/deploy-module.sh <module[,module2,...]> <commit-message> [consuming-apps...] [all]
# Example: ./deploy/scripts/deploy-module.sh auth "Fix ResetPassword component" learn
# Example: ./deploy/scripts/deploy-module.sh auth,notifications "Add email on reset" learn govern
# Example: ./deploy/scripts/deploy-module.sh auth "Fix ResetPassword component" learn all
# Example: ./deploy/scripts/deploy-module.sh auth,notifications "Refactor shared modules" learn govern all

set -e
set -u
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

error() { echo -e "${RED}❌ Error: $1${NC}" >&2; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}▶ $1${NC}"; }

# Cleanup on error
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Deployment failed at step: ${CURRENT_STEP:-unknown}"
        error "Exit code: $exit_code"
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Validate arguments
if [ $# -lt 2 ]; then
    error "Usage: $0 <module[,module2,...]> <commit-message> [consuming-apps...] [all]"
    echo ""
    echo "Examples:"
    echo "  $0 auth 'Fix ResetPassword component' learn                        # Single module, single app"
    echo "  $0 auth,notifications 'Add email on reset' learn govern            # Multiple modules, multiple apps"
    echo "  $0 auth 'Fix ResetPassword component' learn all                    # Deploy to staging and main"
    echo "  $0 auth,notifications 'Refactor shared modules' learn govern all   # Multiple modules to prod"
    echo ""
    echo "Available modules: auth, notifications, organisation"
    echo "Available apps:    learn, hub, govern"
    echo ""
    echo "Workflow:"
    echo "  1. Deploy to dev first:    $0 auth 'message' learn"
    echo "  2. Test in dev environment"
    echo "  3. Deploy to prod:         $0 auth 'message' learn all  (deploys to staging + main)"
    echo ""
    echo "Note: 'all' deploys to staging and main branches (dev is already deployed separately)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse modules (comma-separated first arg)
# ---------------------------------------------------------------------------
IFS=',' read -ra MODULES <<< "$1"
COMMIT_MESSAGE=$2
shift 2

# Check if last argument is "all"
DEPLOY_ALL_BRANCHES=false
if [ $# -gt 0 ] && [ "${@: -1}" = "all" ]; then
    DEPLOY_ALL_BRANCHES=true
    set -- "${@:1:$(($#-1))}"
fi

# Default consuming apps if none specified
if [ $# -eq 0 ]; then
    CONSUMING_APPS=("learn")
else
    CONSUMING_APPS=("$@")
fi

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
VALID_MODULES=("auth" "notifications" "organisation")
for mod in "${MODULES[@]}"; do
    mod="$(echo "$mod" | tr -d '[:space:]')"
    if [[ ! " ${VALID_MODULES[@]} " =~ " ${mod} " ]]; then
        error "Invalid module name: $mod"
        echo "Valid modules: ${VALID_MODULES[*]}"
        exit 1
    fi
done

VALID_APPS=("learn" "hub" "govern")
for app in "${CONSUMING_APPS[@]}"; do
    if [[ ! " ${VALID_APPS[@]} " =~ " ${app} " ]]; then
        error "Invalid consuming app: $app"
        echo "Valid apps: ${VALID_APPS[*]}"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Workspace setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

info "Workspace root: $WORKSPACE_ROOT"
info "Modules: ${MODULES[*]}"
info "Commit message: $COMMIT_MESSAGE"
info "Consuming apps: ${CONSUMING_APPS[*]}"
if [ "$DEPLOY_ALL_BRANCHES" = true ]; then
    info "Branch deployment: staging, main (production branches)"
    warning "⚠️  Make sure you've tested in dev first!"
    info "Skipping module build/push (assuming already done in dev deployment)"
else
    info "Branch deployment: dev only (testing branch)"
fi

# ---------------------------------------------------------------------------
# Per-module state (parallel arrays, indexed same as MODULES)
# ---------------------------------------------------------------------------
MODULE_COMMITS=()
MODULE_COMMIT_SHORTS=()

# Seed initial HEAD commits for each module
for mod in "${MODULES[@]}"; do
    mod="$(echo "$mod" | tr -d '[:space:]')"
    MODULE_DIR="$WORKSPACE_ROOT/$mod"
    if [ ! -d "$MODULE_DIR" ]; then
        error "Module directory not found: $MODULE_DIR"
        exit 1
    fi
    if [ ! -f "$MODULE_DIR/package.json" ]; then
        error "package.json not found in $MODULE_DIR"
        exit 1
    fi
    cd "$MODULE_DIR"
    MODULE_COMMITS+=("$(git rev-parse HEAD)")
    MODULE_COMMIT_SHORTS+=("$(git rev-parse --short HEAD)")
done

info "Current module commits:"
for i in "${!MODULES[@]}"; do
    info "  ${MODULES[$i]}: ${MODULE_COMMIT_SHORTS[$i]}"
done

# ---------------------------------------------------------------------------
# Steps 1 + 2: Build, commit, push each module (skipped when "all" is used)
# ---------------------------------------------------------------------------
if [ "$DEPLOY_ALL_BRANCHES" = false ]; then
    for i in "${!MODULES[@]}"; do
        mod="${MODULES[$i]}"
        mod="$(echo "$mod" | tr -d '[:space:]')"
        MODULE_DIR="$WORKSPACE_ROOT/$mod"
        MODULE_PKG="staysecure-$mod"

        CURRENT_STEP="Module cleanup and build: $mod"
        step "Step 1 [$mod]: Cleaning and rebuilding $mod module"

        cd "$MODULE_DIR"

        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        info "Current branch: $CURRENT_BRANCH"

        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            info "Uncommitted changes detected (will be committed in Step 2):"
            git status --short
        fi

        # Nuclear cleanup
        info "Nuclear cleanup: removing build artifacts and caches..."
        rm -rf node_modules dist package-lock.json .vite node_modules/.vite
        info "Clearing Vite cache..."
        rm -rf node_modules/.cache .cache .turbo .vite-cache
        find node_modules -name ".vite" -type d -exec rm -rf {} + 2>/dev/null || true
        find . -name ".vite-cache" -type d -exec rm -rf {} + 2>/dev/null || true
        success "Vite cache cleared"
        npm cache clean --force
        success "Cleaned build artifacts and caches"

        # Install dependencies
        info "Installing dependencies..."
        if ! npm install --legacy-peer-deps; then
            error "npm install failed for $mod"
            exit 1
        fi
        success "Dependencies installed"

        # Build
        info "Building $mod..."
        if [ -d "dist" ]; then
            warning "dist directory still exists, removing it..."
            rm -rf dist
        fi
        if ! npm run build; then
            error "Build failed for $mod"
            exit 1
        fi
        success "Build completed"

        # Verify dist
        if [ ! -d "dist" ] || [ -z "$(ls -A dist 2>/dev/null)" ]; then
            error "dist directory is empty or missing after build for $mod"
            exit 1
        fi

        DIST_AGE=$(find dist -type f -name "*.js" | head -1 | xargs stat -f "%m" 2>/dev/null || find dist -type f -name "*.js" | head -1 | xargs stat -c "%Y" 2>/dev/null || echo "0")
        CURRENT_TIME=$(date +%s)
        if [ -n "$DIST_AGE" ] && [ "$DIST_AGE" != "0" ]; then
            AGE_DIFF=$((CURRENT_TIME - DIST_AGE))
            if [ "$AGE_DIFF" -gt 60 ]; then
                error "Dist files appear to be older than 60 seconds for $mod — build may have failed or used stale cache"
                exit 1
            fi
        fi
        success "Dist files verified"

        # Step 2: Commit and push this module
        CURRENT_STEP="Module commit and push: $mod"
        step "Step 2 [$mod]: Committing and pushing $mod module"

        info "Staging all changes..."
        git add -A

        if [ -d "dist" ] && [ -n "$(ls -A dist 2>/dev/null)" ]; then
            info "Explicitly staging dist files..."
            if ! git add dist/ 2>/dev/null; then
                info "Regular add failed, trying force add for dist files..."
                git add -f dist/
            fi
        fi

        if git diff --staged --quiet; then
            info "No changes to commit after build (dist files may already be committed)"

            if ! git diff --quiet HEAD -- 'src/'; then
                warning "Uncommitted source file changes detected:"
                git diff --stat HEAD -- 'src/'
                error "Please commit source file changes before deploying"
                exit 1
            fi

            if [ -d "dist" ] && [ -n "$(ls -A dist 2>/dev/null)" ]; then
                info "Dist files exist and appear to be already committed"
                if git ls-files --error-unmatch dist/ >/dev/null 2>&1; then
                    if git diff --quiet HEAD -- dist/; then
                        success "Dist files are already committed and up to date"
                    else
                        warning "Dist files differ from HEAD"
                        git status --short dist/
                    fi
                else
                    warning "Dist files exist but aren't tracked — they should be committed"
                fi
            fi

            LOCAL_COMMIT=$(git rev-parse HEAD)
            REMOTE_COMMIT=$(git rev-parse origin/$CURRENT_BRANCH 2>/dev/null || echo "")

            if [ -n "$REMOTE_COMMIT" ] && [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
                success "Already up to date with origin/$CURRENT_BRANCH — skipping commit and push"
            elif [ -n "$REMOTE_COMMIT" ] && git merge-base --is-ancestor "$REMOTE_COMMIT" "$LOCAL_COMMIT" 2>/dev/null; then
                info "Pushing existing commits to origin/$CURRENT_BRANCH..."
                if ! git push origin "$CURRENT_BRANCH"; then
                    error "Failed to push $mod"
                    exit 1
                fi
                success "Pushed to origin/$CURRENT_BRANCH"
            fi
        else
            info "Changes to commit:"
            git status --short

            info "Committing with message: '$COMMIT_MESSAGE'"
            if ! git commit -m "$COMMIT_MESSAGE"; then
                error "Failed to commit $mod"
                exit 1
            fi
            success "Changes committed"

            LOCAL_COMMIT=$(git rev-parse HEAD)
            REMOTE_COMMIT=$(git rev-parse origin/$CURRENT_BRANCH 2>/dev/null || echo "")

            if [ -n "$REMOTE_COMMIT" ] && [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
                success "Already up to date — skipping push"
            else
                info "Pushing to origin/$CURRENT_BRANCH..."
                if ! git push origin "$CURRENT_BRANCH"; then
                    error "Failed to push $mod"
                    exit 1
                fi
                success "Pushed to origin/$CURRENT_BRANCH"
            fi
        fi

        # Capture final commit for this module
        MODULE_COMMITS[$i]="$(git rev-parse HEAD)"
        MODULE_COMMIT_SHORTS[$i]="$(git rev-parse --short HEAD)"
        info "$mod commit after push: ${MODULE_COMMIT_SHORTS[$i]}"

    done  # End module build loop
else
    info "Skipping module build/push (using existing commits):"
    for i in "${!MODULES[@]}"; do
        info "  ${MODULES[$i]}: ${MODULE_COMMIT_SHORTS[$i]}"
    done
fi

# ---------------------------------------------------------------------------
# Step 3: Update consuming apps
# ---------------------------------------------------------------------------
CURRENT_STEP="Consuming apps update"
step "Step 3: Updating consuming apps"

if [ "$DEPLOY_ALL_BRANCHES" = true ]; then
    DEPLOY_BRANCHES=("staging" "main")
    info "Production deployment: will deploy to staging and main branches"
    read -p "⚠️  Have you tested this in dev? Continue to staging/main? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Deployment cancelled. Deploy to dev first with: $0 ${MODULES[*]} '$COMMIT_MESSAGE' ${CONSUMING_APPS[*]}"
        exit 0
    fi
else
    DEPLOY_BRANCHES=("dev")
fi

SUCCESSFUL_APP_COMMITS=0

for app in "${CONSUMING_APPS[@]}"; do
    APP_DIR="$WORKSPACE_ROOT/$app"

    if [ ! -d "$APP_DIR" ]; then
        warning "App directory not found: $APP_DIR (skipping)"
        continue
    fi

    if [ ! -f "$APP_DIR/package.json" ]; then
        warning "package.json not found in $APP_DIR (skipping)"
        continue
    fi

    cd "$APP_DIR"

    if [ "$DEPLOY_ALL_BRANCHES" = true ]; then
        info "Fetching latest changes from origin..."
        git fetch origin --quiet || true
    fi

    for APP_BRANCH in "${DEPLOY_BRANCHES[@]}"; do
        info "Updating $app on branch: $APP_BRANCH..."

        if git show-ref --verify --quiet refs/heads/"$APP_BRANCH"; then
            info "Switching to existing branch: $APP_BRANCH"
            if ! git checkout "$APP_BRANCH"; then
                error "Failed to checkout branch $APP_BRANCH"
                continue
            fi
        elif git show-ref --verify --quiet refs/remotes/origin/"$APP_BRANCH"; then
            info "Branch $APP_BRANCH exists on remote, creating local tracking branch"
            if ! git checkout -b "$APP_BRANCH" "origin/$APP_BRANCH"; then
                error "Failed to create local branch $APP_BRANCH"
                continue
            fi
        else
            if [ "$APP_BRANCH" = "dev" ]; then
                info "Creating dev branch from current branch"
                if ! git checkout -b dev 2>/dev/null; then
                    if ! git checkout dev; then
                        error "Failed to create/checkout dev branch"
                        continue
                    fi
                fi
            else
                warning "Branch $APP_BRANCH does not exist locally or remotely, skipping"
                continue
            fi
        fi

        CURRENT_APP_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$APP_BRANCH")
        if [ "$CURRENT_APP_BRANCH" != "$APP_BRANCH" ]; then
            warning "Branch mismatch: expected $APP_BRANCH, got $CURRENT_APP_BRANCH"
        fi

        # Nuclear cleanup
        info "Nuclear cleanup in $app..."
        rm -rf node_modules dist .vite node_modules/.vite package-lock.json
        npm cache clean --force > /dev/null 2>&1 || true

        # Remove all modules being deployed from node_modules
        for mod in "${MODULES[@]}"; do
            mod="$(echo "$mod" | tr -d '[:space:]')"
            MODULE_PKG="staysecure-$mod"
            if [ -d "node_modules/$MODULE_PKG" ]; then
                info "Removing existing $MODULE_PKG from node_modules..."
                rm -rf "node_modules/$MODULE_PKG"
            fi
        done

        # Build install targets for all modules at once
        INSTALL_TARGETS=()
        for mod in "${MODULES[@]}"; do
            mod="$(echo "$mod" | tr -d '[:space:]')"
            INSTALL_TARGETS+=("staysecure-${mod}@github:kahuna-rayn/staysecure-${mod}#main")
        done

        info "Installing modules: ${INSTALL_TARGETS[*]}"
        if ! npm install "${INSTALL_TARGETS[@]}" --legacy-peer-deps --save --ignore-scripts; then
            error "Failed to install modules in $app"
            continue
        fi
        success "Installed ${#MODULES[@]} module(s) and regenerated package-lock.json"

        # Verify each module's installed commit matches what we pushed
        ALL_VERIFIED=true
        for i in "${!MODULES[@]}"; do
            mod="${MODULES[$i]}"
            mod="$(echo "$mod" | tr -d '[:space:]')"
            MODULE_PKG="staysecure-$mod"
            EXPECTED_COMMIT="${MODULE_COMMITS[$i]}"
            EXPECTED_SHORT="${MODULE_COMMIT_SHORTS[$i]}"

            info "Verifying installed version of $MODULE_PKG..."

            INSTALLED_COMMIT=""
            if [ -f "package-lock.json" ]; then
                INSTALLED_COMMIT=$(grep -A 5 "\"$MODULE_PKG\"" package-lock.json | grep "resolved" | sed -E 's/.*#([a-f0-9]+).*/\1/' | head -1 || echo "")
            fi

            if [ -z "$INSTALLED_COMMIT" ]; then
                INSTALLED_VERSION_RAW=$(npm list "$MODULE_PKG" --depth=0 2>/dev/null | grep "$MODULE_PKG" || echo "")
                if [[ "$INSTALLED_VERSION_RAW" == *"#"* ]]; then
                    INSTALLED_COMMIT=$(echo "$INSTALLED_VERSION_RAW" | sed -E 's/.*#([a-f0-9]+).*/\1/' | head -1)
                fi
            fi

            if [ -z "$INSTALLED_COMMIT" ]; then
                warning "⚠️  Could not determine installed commit for $MODULE_PKG"
                continue
            fi

            info "Installed $MODULE_PKG commit: $INSTALLED_COMMIT"

            EXPECTED_FULL=$(cd "$WORKSPACE_ROOT/$mod" && git rev-parse HEAD 2>/dev/null || echo "$EXPECTED_COMMIT")
            if [ "$INSTALLED_COMMIT" = "$EXPECTED_FULL" ] || [ "$INSTALLED_COMMIT" = "$EXPECTED_SHORT" ] || [[ "$EXPECTED_FULL" == "$INSTALLED_COMMIT"* ]]; then
                success "✅ VERIFIED $MODULE_PKG: installed ($INSTALLED_COMMIT) matches pushed ($EXPECTED_SHORT)"
            else
                error "❌ MISMATCH $MODULE_PKG: installed ($INSTALLED_COMMIT) ≠ pushed ($EXPECTED_SHORT)"
                warning "Attempting force reinstall of $MODULE_PKG..."

                rm -rf "node_modules/$MODULE_PKG"
                npm cache clean --force > /dev/null 2>&1 || true
                info "Waiting 3 seconds for GitHub to propagate..."
                sleep 3

                if ! npm install "github:kahuna-rayn/staysecure-${mod}#main" --force --legacy-peer-deps --ignore-scripts; then
                    error "Failed to force reinstall $MODULE_PKG"
                    ALL_VERIFIED=false
                    continue
                fi

                INSTALLED_COMMIT_AFTER=""
                if [ -f "package-lock.json" ]; then
                    INSTALLED_COMMIT_AFTER=$(grep -A 5 "\"$MODULE_PKG\"" package-lock.json | grep "resolved" | sed -E 's/.*#([a-f0-9]+).*/\1/' | head -1 || echo "")
                fi
                if [ -z "$INSTALLED_COMMIT_AFTER" ]; then
                    INSTALLED_VERSION_AFTER=$(npm list "$MODULE_PKG" --depth=0 2>/dev/null | grep "$MODULE_PKG" || echo "")
                    if [[ "$INSTALLED_VERSION_AFTER" == *"#"* ]]; then
                        INSTALLED_COMMIT_AFTER=$(echo "$INSTALLED_VERSION_AFTER" | sed -E 's/.*#([a-f0-9]+).*/\1/')
                    fi
                fi

                if [ -n "$INSTALLED_COMMIT_AFTER" ] && ([ "$INSTALLED_COMMIT_AFTER" = "$EXPECTED_FULL" ] || [ "$INSTALLED_COMMIT_AFTER" = "$EXPECTED_SHORT" ] || [[ "$EXPECTED_FULL" == "$INSTALLED_COMMIT_AFTER"* ]]); then
                    success "✅ VERIFIED after force reinstall: $MODULE_PKG ($INSTALLED_COMMIT_AFTER) matches ($EXPECTED_SHORT)"
                else
                    error "❌ FAILED after force reinstall: $MODULE_PKG ($INSTALLED_COMMIT_AFTER) ≠ ($EXPECTED_SHORT)"
                    error "Try manually: npm install github:kahuna-rayn/staysecure-${mod}#main --force --legacy-peer-deps"
                    ALL_VERIFIED=false
                fi
            fi
        done  # End module verification loop

        if [ "$ALL_VERIFIED" = false ]; then
            warning "One or more modules failed verification — committing anyway but check manually"
        fi

        # Stage all changes
        info "Staging all changes in $app..."
        git add -A

        if git diff --staged --quiet; then
            info "No changes to commit in $app/$APP_BRANCH (module versions may already be current)"

            # Push any unpushed commits
            AHEAD_COUNT=0
            if git rev-parse --abbrev-ref @{u} > /dev/null 2>&1; then
                AHEAD_COUNT=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
            elif git show-ref --verify --quiet refs/remotes/origin/"$APP_BRANCH"; then
                AHEAD_COUNT=$(git rev-list --count origin/"$APP_BRANCH"..HEAD 2>/dev/null || echo "0")
            fi

            if [ "$AHEAD_COUNT" -gt 0 ]; then
                info "Found $AHEAD_COUNT unpushed commit(s) — pushing to origin/$APP_BRANCH..."
                if ! git push origin "$APP_BRANCH"; then
                    error "Failed to push unpushed commits to $APP_BRANCH"
                    continue
                fi
                success "Pushed $AHEAD_COUNT commit(s) to origin/$APP_BRANCH"
                APP_COMMIT=$(git rev-parse --short HEAD)
                info "Deployed $app/$APP_BRANCH at commit: $APP_COMMIT"
                SUCCESSFUL_APP_COMMITS=$((SUCCESSFUL_APP_COMMITS + 1))
            fi
        else
            # Commit all changes
            MODULE_LIST=$(IFS=', '; echo "${MODULES[*]}")
            PKGS_LIST=$(printf "staysecure-%s" "${MODULES[0]}"; for m in "${MODULES[@]:1}"; do printf ", staysecure-%s" "$m"; done)
            info "Committing all changes in $app..."
            if ! git commit -m "Update ${PKGS_LIST} to latest version ($COMMIT_MESSAGE)"; then
                error "Failed to commit in $app"
                continue
            fi
            success "Committed changes in $app"

            info "Pushing $app to origin/$APP_BRANCH..."
            if ! git push origin "$APP_BRANCH"; then
                error "Failed to push $app to $APP_BRANCH"
                continue
            fi
            success "Pushed $app to origin/$APP_BRANCH"
            APP_COMMIT=$(git rev-parse --short HEAD)
            info "Deployed $app/$APP_BRANCH at commit: $APP_COMMIT"
            SUCCESSFUL_APP_COMMITS=$((SUCCESSFUL_APP_COMMITS + 1))
        fi
    done  # End branch loop
done  # End app loop

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
step "Deployment Summary"

success "Module(s) deployed successfully: ${MODULES[*]}"
info "Module commits:"
for i in "${!MODULES[@]}"; do
    info "  ${MODULES[$i]}: ${MODULE_COMMIT_SHORTS[$i]}"
done

if [ "$SUCCESSFUL_APP_COMMITS" -gt 0 ]; then
    info "Consuming apps updated: ${CONSUMING_APPS[*]}"
    info "App commit: ${APP_COMMIT:-no new commit}"
    echo ""
    info "Next steps:"
    echo "  • Vercel will automatically deploy the updated consuming apps"
    echo "  • Check Vercel dashboard for deployment status"
else
    warning "No consuming apps were successfully committed/pushed"
    info "Consuming apps attempted: ${CONSUMING_APPS[*]}"
    echo ""
    warning "Fix any commit errors (lint, tests, etc.) and retry"
fi
echo ""
success "All done! 🚀"
