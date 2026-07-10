# rtk-toggle

Three small, dependency-light scripts to cleanly install, remove, or
restore the [rtk](https://github.com/rtk-ai/rtk) (Rust Token Killer)
integration for your coding agent — without hand-editing config files,
and without touching anything else in your setup.

rtk wires itself into agents in two different ways:

| Agent | Scope | Mechanism |
|---|---|---|
| Claude Code | Global (`~/.claude/`) | A `PreToolUse` hook on `Bash` in `settings.json` that rewrites shell commands through `rtk rewrite`, plus an `@RTK.md` import in `CLAUDE.md` |
| Google Antigravity | Per-project (`.agents/rules/`) | A `.agents/rules/antigravity-rtk-rules.md` file the agent reads as instructions — advisory, not enforced |

If either one ever gets in your way, `rtk-uninstall.sh` removes exactly
that agent's rtk artifacts and nothing else — every other setting is left
untouched. `rtk-reinstall.sh` puts it back later if you change your mind.
Both scripts are idempotent — safe to run more than once — and back up
anything they touch first.

rtk's own `--uninstall` flag only handles the global Claude Code case
("Uninstall only works with --global flag") — it doesn't clean up
project-scoped agents like Antigravity, Cursor, or Windsurf. That gap is
what these scripts fill.

## Usage

```bash
# Never used rtk before? Start here — checks prerequisites, installs the
# rtk binary, and sets up the chosen agent(s) from a clean machine.
./rtk-install.sh --agent claude
./rtk-install.sh --agent antigravity --dir /path/to/project

# Already set up, but it's getting in the way — preview, then remove
./rtk-uninstall.sh --dry-run
./rtk-uninstall.sh
./rtk-uninstall.sh --agent antigravity --dir /path/to/project

# Changed your mind — put it back
./rtk-reinstall.sh
./rtk-reinstall.sh --agent antigravity --dir /path/to/project

# Any script, either agent, at once
./rtk-install.sh --agent all --dir /path/to/project
./rtk-uninstall.sh --agent all --dir /path/to/project
./rtk-reinstall.sh --agent all --dir /path/to/project
```

All three scripts are idempotent — safe to run more than once — and
accept `--agent claude|antigravity|all`, `--dir PATH` (for antigravity),
and `--dry-run`.

### `rtk-install.sh [--agent claude|antigravity|all] [--dir PATH] [--dry-run]`

A friendly entry point for a machine that has no `rtk` binary and no
existing config. Checks for `jq`/`cargo` up front and prints an install
hint (with the right package-manager command, where detectable) if
either is missing, instead of a bare error. It's a thin wrapper — the
actual setup work is identical to `rtk-reinstall.sh` (see below) run
with `--latest`, since a clean machine has no prior version to restore.

### `rtk-uninstall.sh [--agent claude|antigravity|all] [--dir PATH] [--dry-run]`

**`--agent claude`** (default):
1. Backs up `settings.json`, `CLAUDE.md`, `RTK.md`, and
   `hooks/rtk-rewrite.sh` to a timestamped
   `~/.claude/rtk-backup-<timestamp>/` directory.
2. Records how the `rtk` binary was installed (cargo + git commit, or
   cargo + crates.io version), so `rtk-reinstall.sh` can restore the
   exact same one later.
3. Surgically removes the rtk `PreToolUse` hook entry from
   `settings.json` (via `jq`), preserving every other key.
4. Removes the `@RTK.md` import line from `CLAUDE.md`.
5. Deletes `RTK.md` and `hooks/rtk-rewrite.sh`.
6. Uninstalls the `rtk` binary, if it was installed via `cargo`.

**`--agent antigravity`**: backs up and deletes
`<dir>/.agents/rules/antigravity-rtk-rules.md`. Cleans up the
`.agents/rules/` and `.agents/` directories afterward only if they're
now completely empty — it never touches them if you have other rules
files in there.

### `rtk-reinstall.sh [--agent claude|antigravity|all] [--dir PATH] [--latest] [--dry-run]`

**`--agent claude`**: self-contained — doesn't depend on the backups
still existing. Recreates `RTK.md` and the hook script from scratch,
merges the hook back into `settings.json` and the import back into
`CLAUDE.md` (additively, so it won't clobber other changes you've made
to either file since uninstalling), and reinstalls the binary — using
the snapshot `rtk-uninstall.sh` recorded if one is found, or the latest
release otherwise. Pass `--latest` to always grab the newest version.

**`--agent antigravity`**: installs `rtk` if it's missing, then runs
`rtk init --agent antigravity` in the target directory — delegating
content generation to rtk itself rather than hand-copying a template
that can drift out of date.

## How reliable is the Antigravity integration?

Unlike Claude Code's hook (which programmatically rewrites every command),
Antigravity's `.agents/rules/` file is advisory — the model has to choose
to follow it. We measured how often it actually does, across 10 trials
per model, using `test-antigravity-compliance.sh` (below), against the
plain file `rtk init --agent antigravity` generates (no frontmatter):

| Model | Compliant |
|---|---|
| Gemini 3.5 Flash (Low) | 3/10 |
| Gemini 3.5 Flash (Medium) | 2/10 |
| Gemini 3.5 Flash (High) | 3/10 |
| Gemini 3 Flash | 6/10 |
| Gemini 3.1 Pro (High) | 9/10 |
| Gemini 3.1 Pro (Low) | 10/10 |

The split was by model family, not effort tier — all three Gemini 3.5
Flash variants clustered around 20-30% regardless of Low/Medium/High.

**Root cause**: Antigravity's own bundled docs (the `agy-customizations`
skill, `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/`)
state that rules support a `trigger` frontmatter field, and *"Rules with
`trigger: model_decision` [are loaded only when the model decides to].
Only `always_on` rules are loaded unconditionally."* rtk's generated file
has no frontmatter at all — so it wasn't force-loaded, and compliance
came down to whether each model happened to decide to consult it.

**Fix**: `rtk-install.sh`/`rtk-reinstall.sh --agent antigravity` now write
their own rules file with `trigger: always_on` + `description`
frontmatter (same rtk-usage instructions as rtk's own file, just properly
tagged) instead of delegating to `rtk init --agent antigravity`. Re-running
the full test suite against this file:

| Model | Compliant |
|---|---|
| Gemini 3.5 Flash (Low) | 10/10 |
| Gemini 3.5 Flash (Medium) | 10/10 |
| Gemini 3.5 Flash (High) | 10/10 |
| Gemini 3 Flash | 10/10 |
| Gemini 3.1 Pro (High) | 10/10 |
| Gemini 3.1 Pro (Low) | 10/10 |

60/60 across every model tested — the frontmatter, not model capability,
was the actual bottleneck.

### `test-antigravity-compliance.sh [options]`

Reproduces the tables above (or tests your own prompt/models/rules file).
For each (model, trial) pair it:

1. Creates a fresh, uniquely-named disposable git repo under `$HOME` (a
   trusted Antigravity workspace) and installs the rules file via
   `rtk-reinstall.sh --agent antigravity` — i.e. whatever rtk-toggle
   actually ships, not necessarily upstream rtk's own generator.
2. Sends a fixed prompt asking the model to run `git status` via
   `agy --add-dir <repo> --model <model> --print "<prompt>"`, saving the
   exact command and agy's raw output verbatim.
3. **Validates independently of what the model claims**: queries rtk's
   own project-scoped usage log (`rtk gain --project --history`) in that
   repo afterward. rtk only logs commands actually run through it, so a
   model that ran raw `git status` leaves zero trace there — there's no
   way for narrated-but-not-executed compliance to pass.
4. Deletes the disposable repo (unless `--keep-dirs`) but keeps every
   artifact — prompt, exact command, raw agy output, raw validation
   output, and verdict — under `--out` for inspection.

```bash
./test-antigravity-compliance.sh                              # all agy models, 10 trials each
./test-antigravity-compliance.sh --models "Gemini 3.1 Pro (High)" --trials 20
./test-antigravity-compliance.sh --trials 3 --out /tmp/quick-check
```

Requires `rtk` and `agy` (the Antigravity CLI) in `PATH`.

## Requirements

- `bash`, `jq`
- `cargo` (only needed by `rtk-reinstall.sh`, and by `rtk-uninstall.sh`
  if `rtk` was installed via cargo)
- `rtk` itself must support `--agent antigravity` (added after v0.34;
  update with `cargo install --git https://github.com/rtk-ai/rtk rtk --force`
  if you get `invalid value 'antigravity'`)

## Configuration

Set `CLAUDE_DIR` in the environment if your Claude Code config doesn't
live at the default `~/.claude`:

```bash
CLAUDE_DIR=/path/to/.claude ./rtk-uninstall.sh
```

## Not affiliated with rtk-ai/rtk

This is an independent convenience toolkit for people already using
[rtk-ai/rtk](https://github.com/rtk-ai/rtk). It doesn't modify rtk
itself — just the agent-side wiring around it.

## License

MIT — see [LICENSE](LICENSE).
