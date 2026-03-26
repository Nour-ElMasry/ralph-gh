#!/usr/bin/env bash
set -euo pipefail

# ralph-gh uninstaller
# Removes ~/.ralph-gh/ and the ralph-gh symlink

INSTALL_DIR="$HOME/.ralph-gh"
SYMLINK="$HOME/.local/bin/ralph-gh"

echo "================================================"
echo "  ralph-gh Uninstaller"
echo "================================================"
echo ""

# Check if there's a running instance
if [[ -f "$INSTALL_DIR/.lock" ]]; then
    pid=$(cat "$INSTALL_DIR/.lock" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "[WARN] ralph-gh is currently running (PID $pid)."
        echo "       Run 'ralph-gh --kill' first, or pass --force to this script."
        if [[ "${1:-}" != "--force" ]]; then
            exit 1
        fi
        echo "       --force specified, continuing anyway..."
        echo ""
    fi
fi

removed=0

# Remove symlink
if [[ -L "$SYMLINK" ]]; then
    rm "$SYMLINK"
    echo "  Removed symlink: $SYMLINK"
    removed=1
elif [[ -f "$SYMLINK" ]]; then
    rm "$SYMLINK"
    echo "  Removed binary: $SYMLINK"
    removed=1
else
    echo "  No symlink found at $SYMLINK (skipped)"
fi

# Remove install directory
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "  Removed install directory: $INSTALL_DIR"
    removed=1
else
    echo "  No install directory found at $INSTALL_DIR (skipped)"
fi

echo ""

if [[ $removed -gt 0 ]]; then
    echo "ralph-gh has been uninstalled."
else
    echo "Nothing to uninstall — ralph-gh doesn't appear to be installed."
fi

echo ""
echo "Note: Per-project files (.ralph/, .ralph-gh/, .ralphrc) in your"
echo "repos were NOT removed. Delete them manually if you want."
