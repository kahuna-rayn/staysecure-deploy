#!/bin/bash
# Simple git checkout/merge deployment script
# Fast way to merge changes between branches and deploy
# Usage: ./deploy/scripts/git-deploy.sh <app> <source-branch> <target-branch> [target-branch2...]
# Example: ./deploy/scripts/git-deploy.sh learn dev staging main
# Example: ./deploy/scripts/git-deploy.sh learn main staging  (merge main into staging)

set -e
set -u

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

# Validate arguments
if [ $# -lt 3 ]; then
    error "Usage: $0 <app> <source-branch> <target-branch> [target-branch2...]"
    echo ""
    echo "Examples:"
    echo "  $0 learn dev staging main              # Merge dev into staging and main"
    echo "  $0 learn main staging                  # Merge main into staging"
    echo "  $0 hub dev staging                     # Merge dev into staging for hub app"
    echo ""
    echo "Available apps: learn, hub, govern, notifications, auth, organisation"
    exit 1
fi

APP=$1
SOURCE_BRANCH=$2
shift 2
TARGET_BRANCHES=("$@")

# Get workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$WORKSPACE_ROOT/$APP"

# Validate app directory exists
if [ ! -d "$APP_DIR" ]; then
    error "App directory not found: $APP_DIR"
    exit 1
fi

if [ ! -d "$APP_DIR/.git" ]; then
    error "Not a git repository: $APP_DIR"
    exit 1
fi

info "Workspace root: $WORKSPACE_ROOT"
info "App: $APP ($APP_DIR)"
info "Source branch: $SOURCE_BRANCH"
info "Target branches: ${TARGET_BRANCHES[*]}"

cd "$APP_DIR"

# Fetch latest from origin
step "Fetching latest from origin"
git fetch origin --quiet || true
success "Fetched latest changes"

# Verify source branch exists
if ! git show-ref --verify --quiet refs/heads/"$SOURCE_BRANCH" && ! git show-ref --verify --quiet refs/remotes/origin/"$SOURCE_BRANCH"; then
    error "Source branch '$SOURCE_BRANCH' does not exist locally or remotely"
    exit 1
fi

# Checkout source branch first to get latest
step "Checking out source branch: $SOURCE_BRANCH"
if git show-ref --verify --quiet refs/heads/"$SOURCE_BRANCH"; then
    git checkout "$SOURCE_BRANCH"
    git pull origin "$SOURCE_BRANCH" --quiet || true
else
    git checkout -b "$SOURCE_BRANCH" "origin/$SOURCE_BRANCH"
fi
success "Checked out $SOURCE_BRANCH"
SOURCE_COMMIT=$(git rev-parse --short HEAD)
info "Source commit: $SOURCE_COMMIT"

# Process each target branch
for TARGET_BRANCH in "${TARGET_BRANCHES[@]}"; do
    step "Merging $SOURCE_BRANCH into $TARGET_BRANCH"
    
    # Checkout target branch
    if git show-ref --verify --quiet refs/heads/"$TARGET_BRANCH"; then
        info "Checking out existing branch: $TARGET_BRANCH"
        git checkout "$TARGET_BRANCH"
        git pull origin "$TARGET_BRANCH" --quiet || true
    elif git show-ref --verify --quiet refs/remotes/origin/"$TARGET_BRANCH"; then
        info "Creating local tracking branch: $TARGET_BRANCH"
        git checkout -b "$TARGET_BRANCH" "origin/$TARGET_BRANCH"
    else
        warning "Branch $TARGET_BRANCH does not exist locally or remotely"
        read -p "Create new branch $TARGET_BRANCH from $SOURCE_BRANCH? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git checkout -b "$TARGET_BRANCH"
        else
            warning "Skipping $TARGET_BRANCH"
            continue
        fi
    fi
    
    # Check if already up to date
    TARGET_COMMIT=$(git rev-parse HEAD)
    SOURCE_COMMIT_FULL=$(git rev-parse "$SOURCE_BRANCH")
    
    if [ "$TARGET_COMMIT" = "$SOURCE_COMMIT_FULL" ]; then
        success "Already up to date - $TARGET_BRANCH is at same commit as $SOURCE_BRANCH"
        continue
    fi
    
    # Check if source is ancestor (no merge needed, just fast-forward)
    if git merge-base --is-ancestor "$TARGET_COMMIT" "$SOURCE_COMMIT_FULL" 2>/dev/null; then
        info "Fast-forward merge possible"
        git merge "$SOURCE_BRANCH" --ff-only --quiet
        success "Fast-forwarded $TARGET_BRANCH to $SOURCE_BRANCH"
    else
        # Regular merge
        info "Merging $SOURCE_BRANCH into $TARGET_BRANCH..."
        if git merge "$SOURCE_BRANCH" --no-edit --quiet; then
            success "Successfully merged $SOURCE_BRANCH into $TARGET_BRANCH"
        else
            error "Merge conflict detected"
            warning "Resolve conflicts manually and run: git commit"
            read -p "Continue to next branch? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            continue
        fi
    fi
    
    # Push target branch
    info "Pushing $TARGET_BRANCH to origin..."
    if git push origin "$TARGET_BRANCH"; then
        success "Pushed $TARGET_BRANCH to origin"
    else
        error "Failed to push $TARGET_BRANCH"
        warning "Push manually with: git push origin $TARGET_BRANCH"
    fi
done

# Summary
step "Deployment Summary"
success "Git deployment completed!"
info "Source branch: $SOURCE_BRANCH ($SOURCE_COMMIT)"
info "Target branches: ${TARGET_BRANCHES[*]}"
info ""
info "Next steps:"
info "  • Vercel will automatically deploy the updated branches"
info "  • Check Vercel dashboard for deployment status"

