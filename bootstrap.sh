#!/usr/bin/env bash
set -euo pipefail

echo "🔒 Applying zero-trust bootstrap…"
# IMPORTANT: run this while your CWD is the TARGET repo and script path is ../zero-trust-bootstrap/bootstrap.sh
TARGET="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy policy files from bootstrap repo to target
cp -r "$SCRIPT_DIR/.github" "$SCRIPT_DIR/.editorconfig" "$SCRIPT_DIR/.gitattributes" \
      "$SCRIPT_DIR/SECURITY.md" "$SCRIPT_DIR/CONTRIBUTING.md" "$TARGET"/

cd "$TARGET"

git add .github .editorconfig .gitattributes SECURITY.md CONTRIBUTING.md || true
git commit -m "chore: apply zero-trust bootstrap from central repo" || echo "ℹ️ Nothing to commit"
git push origin main || true

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

echo "⚙️ Applying repo security & analysis to $REPO… (best-effort)"
# Enable security features (may be plan-dependent; ignore failures)
gh api -X PATCH "repos/$REPO" -H "Accept: application/vnd.github+json" \
  -f security_and_analysis='{
    "secret_scanning": {"status":"enabled"},
    "secret_scanning_push_protection": {"status":"enabled"},
    "dependabot_security_updates": {"status":"enabled"}
  }' || true

echo "⚙️ Applying branch protection to main…"
# Branch protection (ignore failures if checks not present yet)
gh api -X PUT "repos/$REPO/branches/main/protection" -H "Accept: application/vnd.github+json" \
  -f enforce_admins=true \
  -F required_status_checks.strict=true \
  -F required_status_checks.contexts[]="PR-Fast" \
  -F required_status_checks.contexts[]="CI-All-Files" \
  -f required_pull_request_reviews.dismiss_stale_reviews=true \
  -f required_pull_request_reviews.require_code_owner_reviews=true \
  -f required_pull_request_reviews.required_approving_review_count=1 \
  -f restrictions="null" || true

# Require signed commits if supported
gh api -X POST "repos/$REPO/branches/main/protection/required_signatures" -H "Accept: application/vnd.github+json" || true

# Prefer squash merge, auto-delete branches (best-effort)
gh api -X PATCH "repos/$REPO" -H "Accept: application/vnd.github+json" \
  -f allow_merge_commit=false -f allow_rebase_merge=false -f allow_squash_merge=true \
  -f delete_branch_on_merge=true || true

echo "✅ Bootstrap complete for $REPO"
