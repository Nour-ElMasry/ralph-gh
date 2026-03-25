#!/usr/bin/env bash
set -euo pipefail

# ralph-gh installer
# Sets up ~/.ralph-gh/ with config and scripts

INSTALL_DIR="$HOME/.ralph-gh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo "  ralph-gh Installer"
echo "================================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."
errors=0

if ! command -v claude &>/dev/null; then
    echo "  [FAIL] claude CLI not found"
    echo "         Install: npm install -g @anthropic-ai/claude-code"
    echo "         Then authenticate: claude (follow OAuth flow)"
    errors=$((errors + 1))
else
    echo "  [OK] claude CLI found"
fi

if ! command -v gh &>/dev/null; then
    echo "  [FAIL] gh CLI not found"
    echo "         Install: https://cli.github.com/"
    errors=$((errors + 1))
else
    if gh auth status &>/dev/null; then
        echo "  [OK] gh CLI authenticated"
    else
        echo "  [FAIL] gh CLI not authenticated"
        echo "         Run: gh auth login"
        errors=$((errors + 1))
    fi
fi

if ! command -v git &>/dev/null; then
    echo "  [FAIL] git not found"
    errors=$((errors + 1))
else
    echo "  [OK] git found"
fi

if ! command -v jq &>/dev/null; then
    echo "  [FAIL] jq not found"
    echo "         Install: apt install jq / brew install jq"
    errors=$((errors + 1))
else
    echo "  [OK] jq found"
fi

if [[ $errors -gt 0 ]]; then
    echo ""
    echo "Please install missing prerequisites and re-run."
    exit 1
fi

echo ""

# Create install directory
echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/templates"

# Copy scripts
cp "$SCRIPT_DIR/ralph-gh.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/lib/"*.sh "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/templates/"*.md "$INSTALL_DIR/templates/"

# Make executable
chmod +x "$INSTALL_DIR/ralph-gh.sh"
chmod +x "$INSTALL_DIR/lib/"*.sh

# Create config if it doesn't exist
if [[ ! -f "$INSTALL_DIR/ralph-gh.conf" ]]; then
    cp "$SCRIPT_DIR/ralph-gh.conf.example" "$INSTALL_DIR/ralph-gh.conf"
    echo "Created config: $INSTALL_DIR/ralph-gh.conf"
    echo "  -> Edit this file to set RALPH_GH_REPO and RALPH_GH_WORKSPACE"
else
    echo "Config already exists: $INSTALL_DIR/ralph-gh.conf (not overwritten)"
fi

echo ""
echo "================================================"
echo "  Installation complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit config:"
echo "     \$EDITOR $INSTALL_DIR/ralph-gh.conf"
echo ""
echo "  2. Set RALPH_GH_REPO and RALPH_GH_WORKSPACE"
echo ""
echo "  3. (Optional) Add a project-specific prompt:"
echo "     Create .ralph/PROMPT.md in your repo root"
echo ""
echo "  4. Create the 'ralph' label on your repo:"
echo "     gh label create ralph --repo OWNER/REPO --description 'ralph-gh automation' --color '0E8A16'"
echo ""
echo "  5. Run ralph-gh:"
echo "     $INSTALL_DIR/ralph-gh.sh"
echo ""
echo "  Or run in tmux:"
echo "     tmux new -s ralph-gh '$INSTALL_DIR/ralph-gh.sh'"
echo ""
echo "  Or add to PATH:"
echo "     ln -s $INSTALL_DIR/ralph-gh.sh /usr/local/bin/ralph-gh"
echo ""
