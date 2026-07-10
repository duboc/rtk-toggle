#!/usr/bin/env bash
# Friendly first-run installer for rtk (https://github.com/rtk-ai/rtk).
# Checks prerequisites with actionable hints, then sets up the chosen
# agent(s) from a clean machine — no rtk binary, no existing config, and
# no prior uninstall/backup required.
#
# This is a thin wrapper: all the actual setup logic (writing RTK.md, the
# hook script, merging settings.json/CLAUDE.md, or running
# `rtk init --agent antigravity`) lives in rtk-reinstall.sh, which is
# already idempotent and safe to run on a clean machine. rtk-install.sh
# just adds first-run-friendly prerequisite checks and messaging, and
# always installs the latest rtk (there's no prior version to restore).
#
# Usage: ./rtk-install.sh [--agent claude|antigravity|all] [--dir PATH] [--dry-run]
#
# CLAUDE_DIR can be set in the environment to override the default
# ~/.claude location.

set -euo pipefail

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

AGENT="claude"
TARGET_DIR="$PWD"
DRY_RUN=false
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="${2:?--agent requires a value}"; shift 2 ;;
    --dir) TARGET_DIR="${2:?--dir requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$AGENT" in
  claude|antigravity|all) ;;
  *) echo "Unknown --agent value: $AGENT (expected claude, antigravity, or all)" >&2; exit 1 ;;
esac

echo "== rtk install (agent: $AGENT) =="
echo

# 1. Check prerequisites with actionable hints instead of a bare error.
missing=()
command -v jq &>/dev/null || missing+=(jq)
command -v cargo &>/dev/null || missing+=(cargo)

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing prerequisites: ${missing[*]}"
  echo
  for dep in "${missing[@]}"; do
    case "$dep" in
      jq)
        echo "  jq — required to edit settings.json safely."
        if command -v apt-get &>/dev/null; then
          echo "    sudo apt-get install jq"
        elif command -v brew &>/dev/null; then
          echo "    brew install jq"
        elif command -v dnf &>/dev/null; then
          echo "    sudo dnf install jq"
        else
          echo "    https://jqlang.github.io/jq/download/"
        fi
        ;;
      cargo)
        echo "  cargo — required to build/install the rtk binary."
        echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        ;;
    esac
    echo
  done
  echo "Install the above, then re-run this script."
  exit 1
fi

echo "Prerequisites OK (jq, cargo found)."
echo

# 2. Delegate the actual setup to rtk-reinstall.sh. --latest: on a clean
#    machine there's no prior install snapshot to restore, so always grab
#    the newest rtk.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REINSTALL="$SCRIPT_DIR/rtk-reinstall.sh"

if [[ ! -x "$REINSTALL" ]]; then
  echo "Expected to find rtk-reinstall.sh next to this script at $REINSTALL, but it's missing or not executable." >&2
  exit 1
fi

ARGS=(--agent "$AGENT" --dir "$TARGET_DIR" --latest)
$DRY_RUN && ARGS+=(--dry-run)

"$REINSTALL" "${ARGS[@]}"

# 3. Friendly "what's next" summary.
echo
if $DRY_RUN; then
  echo "Dry run complete — nothing was installed. Re-run without --dry-run to apply."
  exit 0
fi

echo "== Done =="
case "$AGENT" in
  claude)
    echo "Claude Code will now transparently rewrite your next Bash commands through rtk."
    echo "Verify with: rtk gain"
    ;;
  antigravity)
    echo "Open $TARGET_DIR in Google Antigravity — it will now read .agents/rules/antigravity-rtk-rules.md"
    echo "and prefer rtk <cmd> over raw shell commands."
    ;;
  all)
    echo "Claude Code will transparently rewrite Bash commands through rtk."
    echo "Google Antigravity will read the rules file in $TARGET_DIR and prefer rtk <cmd>."
    echo "Verify with: rtk gain"
    ;;
esac
