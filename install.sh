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

# Copy scripts
cp "$SCRIPT_DIR/ralph-gh.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/lib/"*.sh "$INSTALL_DIR/lib/"

# Make executable
chmod +x "$INSTALL_DIR/ralph-gh.sh"
chmod +x "$INSTALL_DIR/lib/"*.sh

# Create config if it doesn't exist
if [[ ! -f "$INSTALL_DIR/ralph-gh.conf" ]]; then
    cp "$SCRIPT_DIR/ralph-gh.conf.example" "$INSTALL_DIR/ralph-gh.conf"
    echo "Created config: $INSTALL_DIR/ralph-gh.conf"
    echo "  -> Edit to customize timeouts, thresholds, and allowed tools"
else
    echo "Config already exists: $INSTALL_DIR/ralph-gh.conf (not overwritten)"
fi

# Add to PATH via symlink
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/ralph-gh.sh" "$BIN_DIR/ralph-gh"
echo "Symlinked: $BIN_DIR/ralph-gh -> $INSTALL_DIR/ralph-gh.sh"

echo ""
echo "================================================"
echo "  Installation complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. cd into your repo and set up the ralph label:"
echo "     cd /path/to/your/repo"
echo "     ralph-gh setup"
echo ""
echo "  2. (Optional) Add a project-specific prompt:"
echo "     Create .ralph/PROMPT.md in your repo root"
echo ""
echo "  3. Run ralph-gh from inside your repo:"
echo "     ralph-gh run              # Poll for labeled issues"
echo "     ralph-gh run 42           # Work on specific issue"
echo "     ralph-gh run 42 & ralph-gh run 99  # Parallel"
echo ""
