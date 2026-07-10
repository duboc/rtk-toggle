# rtk-toggle

Two small, dependency-light scripts to cleanly enable or disable the
[rtk](https://github.com/rtk-ai/rtk) (Rust Token Killer) integration for
your coding agent — without hand-editing config files, and without
touching anything else in your setup.

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
# Claude Code (default agent, global) — preview, then apply
./rtk-uninstall.sh --dry-run
./rtk-uninstall.sh
./rtk-reinstall.sh

# Google Antigravity — scoped to a project directory (default: cwd)
./rtk-uninstall.sh --agent antigravity --dir /path/to/project --dry-run
./rtk-uninstall.sh --agent antigravity --dir /path/to/project
./rtk-reinstall.sh --agent antigravity --dir /path/to/project

# Both at once
./rtk-uninstall.sh --agent all --dir /path/to/project
./rtk-reinstall.sh --agent all --dir /path/to/project
```

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
