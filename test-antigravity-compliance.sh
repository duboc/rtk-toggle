#!/usr/bin/env bash
# Empirically measures how often agy (Google Antigravity CLI) actually
# follows the .agents/rules/antigravity-rtk-rules.md file that
# `rtk init --agent antigravity` installs, broken down by model. This is
# the exact methodology behind the compliance numbers documented in
# README.md.
#
#   INPUT       A fixed, disposable git repo (just an initial commit of
#               README.md) plus a fixed prompt asking the model to run
#               `git status` — the same command rtk's own rules file
#               names as its suggested test.
#
#   OUTPUT      agy's raw stdout+stderr, saved verbatim per trial. We
#               never rely on a summarized/truncated view of it.
#
#   VALIDATION  NOT the model's self-reported text — it can claim
#               anything. We independently query rtk's own project-
#               scoped usage log (`rtk gain --project --history`, run
#               from inside that trial's directory) afterward. rtk only
#               logs commands that were actually executed through it, so
#               if the model ran raw `git status`, NOTHING shows up —
#               there's no way to fake a passing result here.
#
#   ISOLATION   Every trial gets a brand-new, uniquely-named directory
#               under the trusted workspace root ($HOME) so agy carries
#               no conversation history between trials, and rtk's
#               project-scoped log (keyed by absolute path) can't
#               accumulate across trials.
#
# Every trial's full input/output/validation is written to its own
# directory under --out, so you can inspect exactly what happened for
# any single run.
#
# Usage:
#   ./test-antigravity-compliance.sh [options]
#
# Options:
#   --models "A,B,C"   Comma-separated model names, must match `agy models`
#                       output exactly. Default: every model `agy models` lists.
#   --trials N          Trials per model. Default: 10.
#   --prompt "..."      Instruction sent to agy. Default: ask it to run
#                       `git status` in the trial directory.
#   --out DIR           Where to save per-trial artifacts + summary.
#                       Default: ./agy-compliance-results/<timestamp>/
#   --keep-dirs         Don't delete each trial's throwaway git repo
#                       afterward (useful for manually poking at what
#                       agy actually left behind).
#   --agy-timeout SECS  Per-trial timeout for the agy call. Default: 70.
#
# Requires: rtk, agy. Uses --dangerously-skip-permissions and
# --add-dir on every agy call — see README.md's "How the compliance
# test works" section for why.

set -uo pipefail

usage() {
  sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
}

MODELS=""
TRIALS=10
PROMPT_TEMPLATE='In the directory %s, run `git status` via the shell and report the exact command you executed and its full output.'
OUT=""
KEEP_DIRS=false
AGY_TIMEOUT=70

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models) MODELS="${2:?--models requires a value}"; shift 2 ;;
    --trials) TRIALS="${2:?--trials requires a value}"; shift 2 ;;
    --prompt) PROMPT_TEMPLATE="${2:?--prompt requires a value}%s"; shift 2 ;;
    --out) OUT="${2:?--out requires a value}"; shift 2 ;;
    --keep-dirs) KEEP_DIRS=true; shift ;;
    --agy-timeout) AGY_TIMEOUT="${2:?--agy-timeout requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for dep in rtk agy; do
  if ! command -v "$dep" &>/dev/null; then
    echo "$dep is required but not found in PATH." >&2
    exit 1
  fi
done

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${OUT:-./agy-compliance-results/$STAMP}"
WORKROOT="$HOME/.agy-compliance-work-$STAMP"

mkdir -p "$OUT"
rm -rf "$WORKROOT"
mkdir -p "$WORKROOT"

if [[ -n "$MODELS" ]]; then
  IFS=',' read -r -a MODEL_ARR <<< "$MODELS"
else
  mapfile -t MODEL_ARR < <(agy models 2>/dev/null | sed '/^\s*$/d')
fi

if [[ ${#MODEL_ARR[@]} -eq 0 ]]; then
  echo "No models to test (agy models returned nothing, and --models wasn't given)." >&2
  exit 1
fi

slugify() { echo "$1" | tr -c 'A-Za-z0-9' '-' | tr -s '-' | sed 's/^-\|-$//g'; }

echo "== agy antigravity-rules compliance test ==" | tee "$OUT/manifest.txt"
{
  echo "Timestamp: $STAMP"
  echo "Trials per model: $TRIALS"
  echo "Models: ${MODEL_ARR[*]}"
  echo "agy version: $(agy --version 2>/dev/null)"
  echo "rtk version: $(rtk --version 2>/dev/null)"
} | tee -a "$OUT/manifest.txt"
echo

declare -A PASS_COUNT

for model in "${MODEL_ARR[@]}"; do
  slug=$(slugify "$model")
  PASS_COUNT["$model"]=0

  for i in $(seq -w 1 "$TRIALS"); do
    trial_out="$OUT/$slug/trial-$i"
    mkdir -p "$trial_out"

    workdir="$WORKROOT/$slug-$i"
    rm -rf "$workdir"
    mkdir -p "$workdir"

    prompt=$(printf "$PROMPT_TEMPLATE" "$workdir")
    echo "$prompt" > "$trial_out/prompt.txt"

    # --- Setup: a disposable git repo with rtk's antigravity rules installed ---
    {
      echo "+ git init"
      git -C "$workdir" init -q
      echo "+ echo hello > README.md && git add README.md"
      echo hello > "$workdir/README.md"
      git -C "$workdir" add README.md
      echo "+ rtk init --agent antigravity"
      (cd "$workdir" && rtk init --agent antigravity)
    } > "$trial_out/setup.txt" 2>&1

    # --- The actual agy invocation, verbatim, saved for transparency ---
    cmd=(agy --add-dir "$workdir" --model "$model" --dangerously-skip-permissions
         --print-timeout "${AGY_TIMEOUT}s" --print "$prompt")
    printf '%q ' "${cmd[@]}" > "$trial_out/command.txt"
    echo >> "$trial_out/command.txt"

    timeout "$((AGY_TIMEOUT + 10))" "${cmd[@]}" > "$trial_out/agy-output.txt" 2>&1
    agy_rc=$?
    echo "(exit code: $agy_rc)" >> "$trial_out/agy-output.txt"

    # --- Validation: rtk's own log, independent of what agy claimed ---
    (cd "$workdir" && rtk gain --project --history) > "$trial_out/rtk-validation.txt" 2>&1

    total=$(grep -oE 'Total commands:\s+[0-9]+' "$trial_out/rtk-validation.txt" | grep -oE '[0-9]+' || true)
    total="${total:-0}"

    if [[ "$total" -ge 1 ]]; then
      verdict="COMPLIANT"
      PASS_COUNT["$model"]=$(( PASS_COUNT["$model"] + 1 ))
    else
      verdict="NOT_COMPLIANT"
    fi
    {
      echo "$verdict"
      echo "reason: rtk's project-scoped log shows $total command(s) actually run through rtk in this trial's directory."
    } > "$trial_out/verdict.txt"

    echo "[$model] trial $i: $verdict"

    $KEEP_DIRS || rm -rf "$workdir"
  done
done

rm -rf "$WORKROOT"

{
  echo
  echo "== SUMMARY =="
  printf '%-30s %s\n' "Model" "Compliant"
  for model in "${MODEL_ARR[@]}"; do
    printf '%-30s %d/%d\n' "$model" "${PASS_COUNT[$model]}" "$TRIALS"
  done
} | tee "$OUT/summary.txt"

{
  echo "model,compliant,trials"
  for model in "${MODEL_ARR[@]}"; do
    echo "\"$model\",${PASS_COUNT[$model]},$TRIALS"
  done
} > "$OUT/summary.csv"

echo
echo "Full per-trial artifacts (prompt, setup log, raw agy output, rtk validation, verdict): $OUT"
