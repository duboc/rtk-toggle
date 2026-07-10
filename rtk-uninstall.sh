#!/usr/bin/env bash
# Cleanly removes the rtk (https://github.com/rtk-ai/rtk) integration from
# Claude Code:
#   - the PreToolUse Bash hook in $CLAUDE_DIR/settings.json
#   - the @RTK.md import in $CLAUDE_DIR/CLAUDE.md
#   - $CLAUDE_DIR/RTK.md and $CLAUDE_DIR/hooks/rtk-rewrite.sh
#   - the rtk binary, if it was installed via cargo
#
# Every touched/removed file is backed up first. Safe to re-run (idempotent).
# Use rtk-reinstall.sh to bring it all back.
#
# Usage: ./rtk-uninstall.sh [--dry-run]
#   --dry-run   Show what would change without touching anything.
#
# CLAUDE_DIR can be set in the environment to override the default
# ~/.claude location.

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "jq is required but not found in PATH. Install it: https://jqlang.github.io/jq/download/" >&2
  exit 1
fi

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
RTK_MD="$CLAUDE_DIR/RTK.md"
HOOK_SCRIPT="$CLAUDE_DIR/hooks/rtk-rewrite.sh"
BACKUP_DIR="$CLAUDE_DIR/rtk-backup-$(date +%Y%m%d-%H%M%S)"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "== rtk uninstall =="
$DRY_RUN && echo "(dry run — no changes will be made)"

mkdir -p "$BACKUP_DIR" 2>/dev/null || true
if ! $DRY_RUN; then mkdir -p "$BACKUP_DIR"; fi

backup() {
  local f="$1"
  if [[ -f "$f" ]]; then
    run cp "$f" "$BACKUP_DIR/$(basename "$f")"
  fi
}

# 1. Record how rtk was installed, for the reinstall script / manual recovery.
if command -v rtk &>/dev/null; then
  RTK_SRC=$(jq -r '.installs | to_entries[] | select(.key | startswith("rtk ")) | .key' \
    "$HOME/.cargo/.crates2.json" 2>/dev/null || true)
  if [[ -n "$RTK_SRC" ]] && ! $DRY_RUN; then
    echo "$RTK_SRC" > "$BACKUP_DIR/rtk-cargo-source.txt"
  fi
  echo "Found rtk binary: $(command -v rtk) ($RTK_SRC)"
fi

# 2. Back up everything we're about to touch or delete.
backup "$SETTINGS"
backup "$CLAUDE_MD"
backup "$RTK_MD"
backup "$HOOK_SCRIPT"

# 3. Remove the rtk PreToolUse hook from settings.json, preserving every
#    other key (env, model, statusLine, effortLevel, other hooks, ...).
if [[ -f "$SETTINGS" ]]; then
  echo "Removing rtk hook from $SETTINGS"
  NEW_SETTINGS=$(jq '
    .hooks.PreToolUse = [
      (.hooks.PreToolUse // [])[]
      | .hooks = [ .hooks[]? | select((.command // "") | contains("rtk-rewrite.sh") | not) ]
      | select((.hooks | length) > 0)
    ]
    | if ((.hooks.PreToolUse // []) | length) == 0 then .hooks |= del(.PreToolUse) else . end
    | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
  ' "$SETTINGS")
  if $DRY_RUN; then
    diff <(cat "$SETTINGS") <(echo "$NEW_SETTINGS") && echo "  (no rtk hook found)"
  else
    echo "$NEW_SETTINGS" > "$SETTINGS.tmp"
    jq empty "$SETTINGS.tmp"   # validate before replacing
    mv "$SETTINGS.tmp" "$SETTINGS"
  fi
else
  echo "No settings.json found at $SETTINGS, skipping."
fi

# 4. Remove the "@RTK.md" import line from CLAUDE.md, plus any leading
#    blank line it leaves behind.
if [[ -f "$CLAUDE_MD" ]]; then
  echo "Removing @RTK.md import from $CLAUDE_MD"
  NEW_CLAUDE_MD=$(grep -v '^@RTK\.md[[:space:]]*$' "$CLAUDE_MD" | sed '/./,$!d')
  if $DRY_RUN; then
    diff <(cat "$CLAUDE_MD") <(echo "$NEW_CLAUDE_MD") && echo "  (no @RTK.md import found)"
  else
    echo "$NEW_CLAUDE_MD" > "$CLAUDE_MD"
  fi
else
  echo "No CLAUDE.md found at $CLAUDE_MD, skipping."
fi

# 5. Delete rtk's own files.
[[ -f "$RTK_MD" ]] && run rm -f "$RTK_MD"
[[ -f "$HOOK_SCRIPT" ]] && run rm -f "$HOOK_SCRIPT"

# 6. Uninstall the rtk binary, if it's cargo-managed.
if command -v rtk &>/dev/null; then
  if command -v cargo &>/dev/null && [[ -n "${RTK_SRC:-}" ]]; then
    echo "Uninstalling rtk cargo binary"
    run cargo uninstall rtk
  else
    echo "rtk binary found at $(command -v rtk) but isn't cargo-managed (or cargo isn't in PATH)."
    echo "Remove it manually if you want it fully gone, e.g.: rm $(command -v rtk)"
  fi
else
  echo "rtk binary not installed, skipping."
fi

echo
if $DRY_RUN; then
  echo "Dry run complete. Re-run without --dry-run to apply."
else
  echo "Done. Backups saved to: $BACKUP_DIR"
  echo "To restore everything, run: ./rtk-reinstall.sh"
fi
