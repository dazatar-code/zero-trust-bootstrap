#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ../zero-trust-bootstrap/verify.sh            # audit current repo (read-only)
#   ../zero-trust-bootstrap/verify.sh --simulate # also create a failing PR to prove gates

SIMULATE="${1:-}"

# Ensure inside a git repo
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then echo "❌ Not inside a git repo"; exit 2; fi
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

command -v gh >/dev/null || { echo "❌ GitHub CLI (gh) not found. Run: gh auth login"; exit 2; }
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [[ -z "$REPO" ]]; then echo "❌ Unable to detect repo with gh"; exit 2; fi

echo "🔎 Auditing $REPO"
PASS=0; FAIL=0
check(){ if [[ "$1" == "true" ]]; then echo "✅ $2"; ((PASS++)); else echo "❌ $2"; ((FAIL++)); fi }

# Files
for f in \
  ".github/CODEOWNERS" \
  ".github/ISSUE_TEMPLATE/bug_report.yml" \
  ".github/ISSUE_TEMPLATE/feature_request.yml" \
  ".github/ISSUE_TEMPLATE/task.yml" \
  ".github/workflows/require-issue-link.yml" \
  ".github/workflows/sync-labels.yml" \
  ".github/workflows/commit-title-lint.yml" \
  ".github/workflows/codeql.yml" \
  "SECURITY.md" \
  "CONTRIBUTING.md" \
  ".editorconfig" \
  ".gitattributes"; do
  [[ -f "$f" ]] && check true "$f present" || check false "$f missing"
done

# Labels
LABELS="$(gh label list --repo "$REPO" 2>/dev/null || true)"
for l in bug feature task security documentation blocked needs-spec triage; do
  if grep -qE "^$l\\s" <<<"$LABELS"; then check true "Label $l exists"; else check false "Label $l missing"; fi
done

# Branch protection
PROTECTION="$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null || true)"
if [[ -n "$PROTECTION" ]]; then
  check true "Branch protection returned JSON"
  grep -q '"require_code_owner_reviews":true' <<<"$PROTECTION" && check true "CODEOWNER reviews required" || check false "CODEOWNER reviews not required"
  grep -q '"required_approving_review_count":1' <<<"$PROTECTION" && check true "Min 1 approving review" || check false "Approving review count not set"
  grep -q '"strict":true' <<<"$PROTECTION" && check true "Strict status checks enabled" || check false "Strict status checks not enabled"
  grep -q 'PR-Fast' <<<"$PROTECTION" && check true "PR-Fast required" || check false "PR-Fast not required"
  grep -q 'CI-All-Files' <<<"$PROTECTION" && check true "CI-All-Files required" || check false "CI-All-Files not required"
else
  check false "Branch protection not configured"
fi

# Security and analysis flags (best-effort)
SETTINGS_JSON="$(gh api -X GET "repos/$REPO" -H "Accept: application/vnd.github+json" 2>/dev/null || true)"
if grep -q '"security_and_analysis"' <<<"$SETTINGS_JSON"; then
  grep -q '"secret_scanning"' <<<"$SETTINGS_JSON" && check true "Secret scanning visible in settings" || check false "Secret scanning not visible"
  grep -q '"secret_scanning_push_protection"' <<<"$SETTINGS_JSON" && check true "Push protection visible" || check false "Push protection not visible"
  grep -q '"dependabot_security_updates"' <<<"$SETTINGS_JSON" && check true "Dependabot security updates visible" || check false "Dependabot updates not visible"
else
  check false "Security & analysis block not visible in API"
fi

# Guard simulation (optional)
if [[ "$SIMULATE" == "--simulate" ]]; then
  echo "🧪 Creating guard-simulation PR (no Issue link)…"
  BR="guard/sim-$(date +%s)"
  git checkout -b "$BR"
  echo "guard-sim $(date -Iseconds)" >> .guard-sim.txt
  git add .guard-sim.txt && git commit -m "chore: guard sim"
  git push -u origin "$BR" || true
  PR_URL="$(gh pr create --title 'chore: guard sim (should fail gates)' --body 'No Issue link on purpose.' 2>/dev/null || true)"
  if [[ -n "$PR_URL" ]]; then
    echo "   PR: $PR_URL"
    ok_blocked="false"
    for i in {1..12}; do
      sleep 10
      CHECKS="$(gh pr checks --exit-status || true)"
      if echo "$CHECKS" | grep -qiE "Require Issue Link.*(fail|✗)|Conventional Commit Title.*(fail|✗)"; then ok_blocked="true"; break; fi
    done
    [[ "$ok_blocked" == "true" ]] && check true "Guards blocked PR without Issue link" || check false "Guards did not block as expected"
    gh pr close --delete-branch >/dev/null 2>&1 || true
    git checkout main && git branch -D "$BR" >/dev/null 2>&1 || true
  else
    check false "Could not create simulation PR (permissions or gh auth?)"
  fi
fi

echo "-------------------------------------------"
echo "✅ Passed: $PASS   ❌ Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
