# 🔒 Zero-Trust Bootstrap

This is the central policy repo for all GitHub projects.

## Enforces
- CODEOWNERS review
- Issue templates (bug, feature, task)
- Labels (auto-synced)
- Require Issue Link workflow
- Conventional Commit title lint
- CodeQL scanning
- SECURITY.md & CONTRIBUTING.md
- EditorConfig & Gitattributes

## Usage
Clone this repo once:
```bash
gh repo clone dazatar-code/zero-trust-bootstrap
```

Apply to a target repo:
```bash
cd <target-repo>
../zero-trust-bootstrap/bootstrap.sh
```
