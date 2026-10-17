#!/usr/bin/env bash
set -euo pipefail

# setup.sh - Create the 'ralph' label on a GitHub repo

REPO="${1:-}"

if [[ -z "$REPO" ]]; then
    # Auto-detect from CWD
    remote_url=$(git remote get-url origin 2>/dev/null) || {
        echo "Usage: ./setup.sh [OWNER/REPO]"
        echo ""
        echo "Or run from inside a git repo for auto-detection."
        exit 1
    }
    REPO=$(echo "$remote_url" | sed -E 's#^.+github\.com[:/]##; s#\.git$##')
    echo "Auto-detected repo: $REPO"
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
