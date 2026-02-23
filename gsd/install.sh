#!/usr/bin/env bash
# GSD Workflow Commands — Installer / Updater
#
# Requires: gh CLI (https://cli.github.com) — authenticated with repo access
#
# Usage:
#   gh api repos/ben-smith-atg/cursor-gsd/contents/install.sh --jq '.content' \
#     | base64 -d | bash
#
# Or clone and run locally:
#   bash ~/.cursor/commands/gsd/install.sh
set -euo pipefail

REPO="ben-smith-atg/cursor-gsd"
DEST="${HOME}/.cursor/commands/gsd"
FILES=(
  setup-gsd.md
  spec-gsd.md
  plan-gsd.md
  build-gsd.md
  verify-gsd.md
  retro-gsd.md
  README.md
)

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI is required. Install from https://cli.github.com" >&2
  exit 1
fi

mkdir -p "$DEST"

echo "Installing GSD commands to ${DEST} ..."
echo ""

for f in "${FILES[@]}"; do
  gh api "repos/${REPO}/contents/${f}" --jq '.content' \
    | base64 -d > "${DEST}/${f}"
  echo "  ✓ ${f}"
done

echo ""
echo "Done. ${#FILES[@]} files installed to ${DEST}"
echo "Restart Cursor to pick up the updated commands."
