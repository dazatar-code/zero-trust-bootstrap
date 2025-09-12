#!/usr/bin/env bash
set -euo pipefail

echo "🔒 Applying zero-trust bootstrap..."
TARGET=$(git rev-parse --show-toplevel)

cp -r .github .editorconfig .gitattributes SECURITY.md CONTRIBUTING.md "$TARGET"/

cd "$TARGET"
git add .github .editorconfig .gitattributes SECURITY.md CONTRIBUTING.md || true
git commit -m "chore: apply zero-trust bootstrap from central repo" || echo "ℹ️ Nothing to commit"
git push origin main

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

echo "⚙️ Applying branch protections to $REPO..."
gh api -X PUT "repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  -f enforce_admins=true \
  -F required_status_checks.strict=true \
  -F required_status_checks.contexts[]="PR-Fast" \
  -F required_status_checks.contexts[]="CI-All-Files" \
  -f required_pull_request_reviews.dismiss_stale_reviews=true \
  -f required_pull_request_reviews.require_code_owner_reviews=true \
  -f required_pull_request_reviews.required_approving_review_count=1 \
  -f restrictions="null" || true

echo "✅ Zero-trust bootstrap applied to $REPO"
