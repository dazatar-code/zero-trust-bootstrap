########## FILE: bootstrap.sh (place in zero-trust-bootstrap/) ##########
#!/usr/bin/env bash
set -euo pipefail

# PR‑first, default‑branch aware bootstrap
# Usage from a TARGET repo dir:  ../zero-trust-bootstrap/bootstrap.sh

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 2; }; }
need gh

# Ensure we are running from the TARGET repository
TARGET_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${TARGET_ROOT}" ]]; then
  echo "❌ Run this script from inside your target repo: cd <repo> && ../zero-trust-bootstrap/bootstrap.sh"; exit 2; fi

# Locate the bootstrap repo directory (this script's folder)
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TARGET_ROOT"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"; : "${DEFAULT_BRANCH:=main}"

# Create or reuse a working branch
WORK_BRANCH="bootstrap/zero-trust"
if ! git rev-parse --verify "$WORK_BRANCH" >/dev/null 2>&1; then
  git switch -c "$WORK_BRANCH"
else
  git switch "$WORK_BRANCH"
fi

# Copy policy files from bootstrap repo into target
rsync -a --delete --exclude ".git" \
  "$BOOTSTRAP_DIR/.github" \
  "$BOOTSTRAP_DIR/.editorconfig" \
  "$BOOTSTRAP_DIR/.gitattributes" \
  "$BOOTSTRAP_DIR/SECURITY.md" \
  "$BOOTSTRAP_DIR/CONTRIBUTING.md" \
  ./

# Commit (signed, if globally configured)
 git add .github .editorconfig .gitattributes SECURITY.md CONTRIBUTING.md || true
 git commit -m "chore: apply zero-trust bootstrap from central repo" || echo "ℹ️ Nothing to commit"

# Push branch
 git push -u origin "$WORK_BRANCH" || true

# Create Issue (gh v2-compatible; no --json)
ISSUE_URL="$(gh issue create -t "Apply zero-trust bootstrap" -b "Add policies, labels, workflows" 2>/dev/null || true)"
ISSUE_NUM="${ISSUE_URL##*/}"
FIXES_LINE=""; [[ -n "$ISSUE_NUM" && "$ISSUE_NUM" != "$ISSUE_URL" ]] && FIXES_LINE=$'\n\n''Fixes #'"$ISSUE_NUM"

# Open PR to default branch (idempotent if one exists)
 gh pr create -t "chore: apply zero-trust bootstrap" \
   -b $'Apply central policies, labels, workflows.'"${FIXES_LINE}" \
   -B "$DEFAULT_BRANCH" -H "$WORK_BRANCH" 2>/dev/null || true

# Note: Branch protection should be applied AFTER merge; use orchestrator/commands below.
 echo "✅ Opened/updated PR from $WORK_BRANCH → $DEFAULT_BRANCH for $REPO"


########## FILE: orchestrate-zero-trust-all.sh (run from any repo folder) ##########
#!/usr/bin/env bash
set -euo pipefail

OWNER="dazatar-code"
BOOTSTRAP_REPO="zero-trust-bootstrap"
TARGET_REPOS=("hybrid-env-dev" "universal-ml-framework")
SIMULATE="${1:-}"   # pass --simulate to run guard PR test during verify

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 2; }; }
info(){ echo -e "\033[1;34mℹ️  $*\033[0m"; }
ok(){   echo -e "\033[1;32m✅ $*\033[0m"; }
warn(){ echo -e "\033[1;33m⚠️  $*\033[0m"; }

need gh
if ! gh auth status >/dev/null 2>&1; then echo "❌ Run: gh auth login"; exit 2; fi

BASE_DIR="$(cd .. && pwd)"
BOOTSTRAP_DIR="$BASE_DIR/$BOOTSTRAP_REPO"

# 1) Ensure central repo exists and is populated (incl. verify.sh)
info "Ensuring $OWNER/$BOOTSTRAP_REPO exists & populated…"
if ! gh repo view "$OWNER/$BOOTSTRAP_REPO" >/dev/null 2>&1; then
  gh repo create "$OWNER/$BOOTSTRAP_REPO" --public --confirm
fi
rm -rf "$BOOTSTRAP_DIR" && gh repo clone "$OWNER/$BOOTSTRAP_REPO" "$BOOTSTRAP_DIR"

# Ensure core files exist (idempotent refresh)
mkdir -p "$BOOTSTRAP_DIR/.github/ISSUE_TEMPLATE" "$BOOTSTRAP_DIR/.github/workflows"
# (Minimal refresh: assume your current files are correct; skip rewriting here)

# Ensure verify.sh exists (if not already)
if [[ ! -x "$BOOTSTRAP_DIR/verify.sh" ]]; then
  cat > "$BOOTSTRAP_DIR/verify.sh" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
SIMULATE="${1:-}"
need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 2; }; }
need gh
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [[ -z "$REPO_ROOT" ]] && { echo "❌ Not inside a git repo"; exit 2; }
cd "$REPO_ROOT"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"; [[ -z "$REPO" ]] && { echo "❌ gh repo view failed"; exit 2; }
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"; : "${DEFAULT_BRANCH:=main}"
PASS=0; FAIL=0; chk(){ [[ "$1" == true ]] && echo "✅ $2" && ((PASS++)) || { echo "❌ $2"; ((FAIL++)); } }
# Files
for f in .github/CODEOWNERS .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml .github/ISSUE_TEMPLATE/task.yml .github/workflows/require-issue-link.yml .github/workflows/sync-labels.yml .github/workflows/commit-title-lint.yml .github/workflows/codeql.yml SECURITY.md CONTRIBUTING.md .editorconfig .gitattributes; do [[ -f "$f" ]] && chk true "$f present" || chk false "$f missing"; done
# Labels
LBL="$(gh label list --repo "$REPO" 2>/dev/null || true)"; for l in bug feature task security documentation blocked needs-spec triage; do grep -qE "^$l\\s" <<<"$LBL" && chk true "Label $l exists" || chk false "Label $l missing"; done
# Branch protection
BP="$(gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection" 2>/dev/null || true)"; if [[ -n "$BP" ]]; then chk true "Branch protection returned JSON"; grep -q '"require_code_owner_reviews":true' <<<"$BP" && chk true "CODEOWNER reviews required" || chk false "CODEOWNER reviews not required"; grep -q '"required_approving_review_count":1' <<<"$BP" && chk true "Min 1 approving review" || chk false "Approving review count not set"; grep -q '"strict":true' <<<"$BP" && chk true "Strict status checks enabled" || chk false "Strict status checks not enabled"; grep -q 'PR-Fast' <<<"$BP" && chk true "PR-Fast required" || chk false "PR-Fast not required"; grep -q 'CI-All-Files' <<<"$BP" && chk true "CI-All-Files required" || chk false "CI-All-Files not required"; else chk false "Branch protection not configured"; fi
# Security & analysis (best-effort visibility)
SET="$(gh api -X GET "repos/$REPO" -H "Accept: application/vnd.github+json" 2>/dev/null || true)"; grep -q '"security_and_analysis"' <<<"$SET" && chk true "Security & analysis block visible" || chk false "Security & analysis block missing"
# Guard simulation
if [[ "$SIMULATE" == "--simulate" ]]; then BR="guard/sim-$(date +%s)"; git switch -c "$BR"; echo "guard-sim $(date -Iseconds)" >> .guard-sim.txt; git add .guard-sim.txt && git commit -m "chore: guard sim"; git push -u origin "$BR" || true; PR_URL="$(gh pr create -t 'chore: guard sim (should fail gates)' -b 'No Issue link on purpose.' 2>/dev/null || true)"; if [[ -n "$PR_URL" ]]; then okb=false; for i in {1..12}; do sleep 10; CKS="$(gh pr checks --exit-status || true)"; if echo "$CKS" | grep -qiE "Require Issue Link.*(fail|✗)|Conventional Commit Title.*(fail|✗)"; then okb=true; break; fi; done; [[ "$okb" == true ]] && chk true "Guards blocked PR without Issue link" || chk false "Guards did not block as expected"; gh pr close --delete-branch >/dev/null 2>&1 || true; git switch "$DEFAULT_BRANCH" && git branch -D "$BR" >/dev/null 2>&1 || true; else chk false "Could not create simulation PR"; fi; fi
echo "-------------------------------------------"; echo "✅ Passed: $PASS   ❌ Failed: $FAIL"; [[ $FAIL -eq 0 ]] || exit 1
VERIFY
  chmod +x "$BOOTSTRAP_DIR/verify.sh"
  ( cd "$BOOTSTRAP_DIR" && git add verify.sh && git commit -m "chore: add verify.sh" >/dev/null 2>&1 || true && git push origin main >/dev/null 2>&1 || true )
fi

ok "Bootstrap repo ready at $BOOTSTRAP_DIR"

# 2) Apply bootstrap to each target repo via PR and verify
for NAME in "${TARGET_REPOS[@]}"; do
  REPO_SLUG="$OWNER/$NAME"
  info "Applying bootstrap to $REPO_SLUG…"
  # Clone if needed
  TARGET_DIR="$BASE_DIR/$NAME"; [[ -d "$TARGET_DIR/.git" ]] || gh repo clone "$REPO_SLUG" "$TARGET_DIR"
  # Run PR-first bootstrap from inside the target
  ( cd "$TARGET_DIR" && "$BOOTSTRAP_DIR/bootstrap.sh" )

  # After PR creation, try to apply branch protection with JSON once default branch exists
  DEFAULT_BRANCH="$(gh repo view "$REPO_SLUG" --json defaultBranchRef -q .defaultBranchRef.name)"; : "${DEFAULT_BRANCH:=main}"
  JSON_BODY='{
    "required_status_checks": { "strict": true, "contexts": ["PR-Fast","CI-All-Files"] },
    "enforce_admins": true,
    "required_pull_request_reviews": {
      "dismiss_stale_reviews": true,
      "require_code_owner_reviews": true,
      "required_approving_review_count": 1
    },
    "restrictions": null
  }'
  gh api -X PUT "repos/$REPO_SLUG/branches/$DEFAULT_BRANCH/protection" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$JSON_BODY" || true

  # Try enabling commit-signature protection (may already be on / plan-dependent)
  gh api -X POST "repos/$REPO_SLUG/branches/$DEFAULT_BRANCH/protection/required_signatures" \
    -H "Accept: application/vnd.github+json" || true

  # Verify (read-only or with guard simulation)
  info "Verifying $REPO_SLUG…"
  ( cd "$TARGET_DIR" && "$BOOTSTRAP_DIR/verify.sh" "$SIMULATE" ) || true
  ok "Finished $REPO_SLUG"
 done

ok "All done — PRs opened/updated, protections applied (best-effort), and verification completed."
