#!/usr/bin/env bash
# Re-enables the rtk (https://github.com/rtk-ai/rtk) integration for a given
# coding agent, after rtk-uninstall.sh removed it.
#
#   --agent claude (default, global, ~/.claude):
#     Reconstructs RTK.md and the hook script from scratch, merges the hook
#     back into settings.json and the @RTK.md import back into CLAUDE.md
#     without clobbering anything else you've changed in either file since
#     uninstalling, and reinstalls the rtk binary.
#
#   --agent antigravity (project-scoped, defaults to the current directory):
#     Runs `rtk init --agent antigravity` in the target directory. Requires
#     the rtk binary; installed first if missing.
#
#   --agent all: does both of the above.
#
# If rtk-uninstall.sh recorded how rtk was installed (a snapshot left in
# $CLAUDE_DIR/rtk-backup-*/rtk-cargo-source.txt), that exact version/commit
# is restored when the binary needs reinstalling. Otherwise the latest rtk
# is installed fresh. Pass --latest to always ignore the snapshot and grab
# the newest version.
#
# Safe to re-run (idempotent).
#
# Usage: ./rtk-reinstall.sh [--agent claude|antigravity|all] [--dir PATH] [--latest] [--dry-run]
#
# CLAUDE_DIR can be set in the environment to override the default
# ~/.claude location.

set -euo pipefail

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

AGENT="claude"
TARGET_DIR="$PWD"
FORCE_LATEST=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="${2:?--agent requires a value}"; shift 2 ;;
    --dir) TARGET_DIR="${2:?--dir requires a value}"; shift 2 ;;
    --latest) FORCE_LATEST=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$AGENT" in
  claude|antigravity|all) ;;
  *) echo "Unknown --agent value: $AGENT (expected claude, antigravity, or all)" >&2; exit 1 ;;
esac

for dep in jq cargo; do
  if ! command -v "$dep" &>/dev/null; then
    echo "$dep is required but not found in PATH." >&2
    exit 1
  fi
done

RTK_GIT_URL_DEFAULT="https://github.com/rtk-ai/rtk"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
RTK_MD="$CLAUDE_DIR/RTK.md"
HOOK_SCRIPT="$CLAUDE_DIR/hooks/rtk-rewrite.sh"
BACKUP_DIR="$CLAUDE_DIR/rtk-backup-$(date +%Y%m%d-%H%M%S)-reinstall"

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

backup() {
  local f="$1"
  if [[ -f "$f" ]]; then
    run mkdir -p "$BACKUP_DIR"
    run cp "$f" "$BACKUP_DIR/$(basename "$f")"
  fi
}

# Installs rtk if it's missing, preferring the exact version/commit
# rtk-uninstall.sh last recorded for $1 (a directory to search for a
# snapshot in), falling back to latest.
ensure_rtk_installed() {
  local search_dir="$1"
  if command -v rtk &>/dev/null; then
    echo "rtk binary already installed: $(command -v rtk) ($(rtk --version))"
    return
  fi

  if $DRY_RUN; then
    echo "[dry-run] would install rtk (none found in PATH)"
    return
  fi

  local snapshot=""
  if ! $FORCE_LATEST; then
    local latest_backup
    latest_backup=$(ls -dt "$search_dir"/rtk-backup-*/ 2>/dev/null | grep -v -- "-reinstall/$" | head -1 || true)
    if [[ -n "$latest_backup" && -f "${latest_backup}rtk-cargo-source.txt" ]]; then
      snapshot=$(cat "${latest_backup}rtk-cargo-source.txt")
    fi
  fi

  if [[ "$snapshot" =~ \(git\+([^#[:space:]]+)#([0-9a-f]+)\) ]]; then
    local url="${BASH_REMATCH[1]}"
    local rev="${BASH_REMATCH[2]}"
    echo "Installing rtk from recorded snapshot: $url @ $rev"
    cargo install --git "$url" --rev "$rev" rtk
  elif [[ "$snapshot" =~ \(registry\+ ]]; then
    local version
    version=$(echo "$snapshot" | grep -oE '^rtk [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
    echo "Installing rtk $version from crates.io (recorded snapshot)"
    cargo install rtk --version "$version"
  else
    echo "No usable install snapshot found — installing latest rtk from $RTK_GIT_URL_DEFAULT"
    cargo install --git "$RTK_GIT_URL_DEFAULT" rtk
  fi
}

reinstall_claude() {
  ensure_rtk_installed "$CLAUDE_DIR"

  run mkdir -p "$CLAUDE_DIR/hooks"
  backup "$SETTINGS"
  backup "$CLAUDE_MD"

  # 1. Recreate RTK.md.
  echo "Writing $RTK_MD"
  if $DRY_RUN; then
    echo "[dry-run] would write $RTK_MD"
  else
    cat > "$RTK_MD" <<'EOF'
# RTK - Rust Token Killer

**Usage**: Token-optimized CLI proxy (60-90% savings on dev operations)

## Meta Commands (always use rtk directly)

```bash
rtk gain              # Show token savings analytics
rtk gain --history    # Show command usage history with savings
rtk discover          # Analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
```

## Installation Verification

```bash
rtk --version         # Should show: rtk X.Y.Z
rtk gain              # Should work (not "command not found")
which rtk             # Verify correct binary
```

⚠️ **Name collision**: If `rtk gain` fails, you may have reachingforthejack/rtk (Rust Type Kit) installed instead.

## Hook-Based Usage

All other commands are automatically rewritten by the Claude Code hook.
Example: `git status` → `rtk git status` (transparent, 0 tokens overhead)

Refer to CLAUDE.md for full command reference.
EOF
  fi

  # 2. Recreate the hook script.
  echo "Writing $HOOK_SCRIPT"
  if $DRY_RUN; then
    echo "[dry-run] would write $HOOK_SCRIPT"
  else
    cat > "$HOOK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# rtk-hook-version: 3
# RTK Claude Code hook — rewrites commands to use rtk for token savings.
# Requires: rtk >= 0.23.0, jq
#
# This is a thin delegating hook: all rewrite logic lives in `rtk rewrite`,
# which is the single source of truth (src/discover/registry.rs).
# To add or change rewrite rules, edit the Rust registry — not this file.
#
# Exit code protocol for `rtk rewrite`:
#   0 + stdout  Rewrite found, no deny/ask rule matched → auto-allow
#   1           No RTK equivalent → pass through unchanged
#   2           Deny rule matched → pass through (Claude Code native deny handles it)
#   3 + stdout  Ask rule matched → rewrite but let Claude Code prompt the user

if ! command -v jq &>/dev/null; then
  echo "[rtk] WARNING: jq is not installed. Hook cannot rewrite commands. Install jq: https://jqlang.github.io/jq/download/" >&2
  exit 0
fi

if ! command -v rtk &>/dev/null; then
  echo "[rtk] WARNING: rtk is not installed or not in PATH. Hook cannot rewrite commands. Install: https://github.com/rtk-ai/rtk#installation" >&2
  exit 0
fi

# Version guard: rtk rewrite was added in 0.23.0.
# Older binaries: warn once and exit cleanly (no silent failure).
RTK_VERSION=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$RTK_VERSION" ]; then
  MAJOR=$(echo "$RTK_VERSION" | cut -d. -f1)
  MINOR=$(echo "$RTK_VERSION" | cut -d. -f2)
  # Require >= 0.23.0
  if [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 23 ]; then
    echo "[rtk] WARNING: rtk $RTK_VERSION is too old (need >= 0.23.0). Upgrade: cargo install rtk" >&2
    exit 0
  fi
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Delegate all rewrite + permission logic to the Rust binary.
REWRITTEN=$(rtk rewrite "$CMD" 2>/dev/null)
EXIT_CODE=$?

case $EXIT_CODE in
  0)
    # Rewrite found, no permission rules matched — safe to auto-allow.
    # If the output is identical, the command was already using RTK.
    [ "$CMD" = "$REWRITTEN" ] && exit 0
    ;;
  1)
    # No RTK equivalent — pass through unchanged.
    exit 0
    ;;
  2)
    # Deny rule matched — let Claude Code's native deny rule handle it.
    exit 0
    ;;
  3)
    # Ask rule matched — rewrite the command but do NOT auto-allow so that
    # Claude Code prompts the user for confirmation.
    ;;
  *)
    exit 0
    ;;
esac

ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

if [ "$EXIT_CODE" -eq 3 ]; then
  # Ask: rewrite the command, omit permissionDecision so Claude Code prompts.
  jq -n \
    --argjson updated "$UPDATED_INPUT" \
    '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": $updated
      }
    }'
else
  # Allow: rewrite the command and auto-allow.
  jq -n \
    --argjson updated "$UPDATED_INPUT" \
    '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "RTK auto-rewrite",
        "updatedInput": $updated
      }
    }'
fi
EOF
    chmod +x "$HOOK_SCRIPT"
  fi

  # 3. Merge the PreToolUse Bash hook back into settings.json (adds the
  #    entry only if it's not already there; leaves every other key
  #    untouched).
  echo "Merging rtk hook into $SETTINGS"
  if [[ -f "$SETTINGS" ]]; then
    NEW_SETTINGS=$(jq --arg cmd "$HOOK_SCRIPT" '
      .hooks = (.hooks // {})
      | .hooks.PreToolUse = (.hooks.PreToolUse // [])
      | if ([.hooks.PreToolUse[]? | .hooks[]? | select((.command // "") | contains("rtk-rewrite.sh"))] | length) > 0
        then .
        else .hooks.PreToolUse += [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]
        end
    ' "$SETTINGS")
    if $DRY_RUN; then
      diff <(cat "$SETTINGS") <(echo "$NEW_SETTINGS") && echo "  (hook already present)"
    else
      echo "$NEW_SETTINGS" > "$SETTINGS.tmp"
      jq empty "$SETTINGS.tmp"   # validate before replacing
      mv "$SETTINGS.tmp" "$SETTINGS"
    fi
  elif $DRY_RUN; then
    echo "[dry-run] would create $SETTINGS with the rtk hook"
  else
    jq -n --arg cmd "$HOOK_SCRIPT" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $cmd}]}]}}' > "$SETTINGS"
  fi

  # 4. Re-add the @RTK.md import to the top of CLAUDE.md if it's missing.
  echo "Ensuring @RTK.md import in $CLAUDE_MD"
  if [[ -f "$CLAUDE_MD" ]]; then
    if grep -q '^@RTK\.md[[:space:]]*$' "$CLAUDE_MD"; then
      $DRY_RUN && echo "  (import already present)"
    elif $DRY_RUN; then
      echo "[dry-run] would prepend @RTK.md import to $CLAUDE_MD"
    else
      { echo "@RTK.md"; echo; cat "$CLAUDE_MD"; } > "$CLAUDE_MD.tmp"
      mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
    fi
  elif $DRY_RUN; then
    echo "[dry-run] would create $CLAUDE_MD with the @RTK.md import"
  else
    printf '@RTK.md\n' > "$CLAUDE_MD"
  fi
}

reinstall_antigravity() {
  local dir="$1"
  ensure_rtk_installed "$CLAUDE_DIR"

  local rules_dir="$dir/.agents/rules"
  local rules_file="$rules_dir/antigravity-rtk-rules.md"

  # We write our own rules file instead of delegating to
  # `rtk init --agent antigravity` because rtk's generated file has no
  # frontmatter. Per Antigravity's own bundled docs
  # (agy-customizations SKILL.md): "Rules with trigger: model_decision
  # [are loaded only when the model decides to]. Only always_on rules
  # are loaded unconditionally." Without a trigger field, compliance is
  # model-dependent (see README's compliance table) — trigger: always_on
  # forces it into context on every turn regardless of model.
  echo "Writing $rules_file"
  if $DRY_RUN; then
    echo "[dry-run] would write $rules_file (with trigger: always_on frontmatter)"
  else
    mkdir -p "$rules_dir"
    cat > "$rules_file" <<'EOF'
---
trigger: always_on
description: Use rtk for token-optimized shell commands
---
# RTK - Rust Token Killer (Google Antigravity)

**Usage**: Token-optimized CLI proxy for shell commands.

## Rule

Always prefix shell commands with `rtk` to minimize token consumption.

Examples:

```bash
rtk git status
rtk cargo test
rtk ls src/
rtk grep "pattern" src/
rtk find "*.rs" .
rtk docker ps
rtk gh pr list
```

## Meta Commands

```bash
rtk gain              # Show token savings
rtk gain --history    # Command history with savings
rtk discover          # Find missed RTK opportunities
rtk proxy <cmd>       # Run raw (no filtering, for debugging)
```

## Why

RTK filters and compresses command output before it reaches the LLM context, saving 60-90% tokens on common operations. Always use `rtk <cmd>` instead of raw commands.
EOF
    echo
    echo "RTK configured for Google Antigravity."
    echo "  Rules: $rules_file (installed, trigger: always_on)"
    echo "  Antigravity will now use rtk commands for token savings."
    echo "  Test with: git status"
  fi
}

echo "== rtk reinstall (agent: $AGENT) =="
$DRY_RUN && echo "(dry run — no changes will be made)"

case "$AGENT" in
  claude) reinstall_claude ;;
  antigravity) reinstall_antigravity "$TARGET_DIR" ;;
  all) reinstall_claude; reinstall_antigravity "$TARGET_DIR" ;;
esac

echo
if $DRY_RUN; then
  echo "Dry run complete. Re-run without --dry-run to apply."
else
  echo "Done. Verify with:"
  echo "  rtk --version"
  echo "  rtk gain"
  echo "Backups (if any) saved to: $BACKUP_DIR"
fi
