#!/usr/bin/env bash
set -euo pipefail

# setup.sh - Create the 'ralph' label on a GitHub repo

REPO="${1:-}"

if [[ -z "$REPO" ]]; then
    echo "Usage: ./setup.sh OWNER/REPO"
    echo ""
    echo "Creates the 'ralph' label on the specified GitHub repository."
    exit 1
fi

echo "Creating 'ralph' label on $REPO..."

if gh label create ralph \
    --repo "$REPO" \
    --description "ralph-gh automation target" \
    --color "0E8A16" 2>/dev/null; then
    echo "Label 'ralph' created successfully!"
else
    echo "Label may already exist (that's fine)."
fi
