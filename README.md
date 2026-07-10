# rtk-toggle

Two small, dependency-light scripts to cleanly enable or disable the
[rtk](https://github.com/rtk-ai/rtk) (Rust Token Killer) Claude Code
integration — without hand-editing JSON, and without touching anything
else in your Claude Code config.

rtk installs itself into Claude Code via:
- a `PreToolUse` hook on `Bash` in `~/.claude/settings.json` that rewrites
  shell commands through `rtk rewrite`
- an `@RTK.md` import at the top of `~/.claude/CLAUDE.md`
- `~/.claude/RTK.md` (rtk's own usage doc) and
  `~/.claude/hooks/rtk-rewrite.sh` (the hook script)

If the auto-rewriting ever gets in your way, `rtk-uninstall.sh` removes
exactly those four things and nothing else — every other setting
(`env`, `model`, `statusLine`, `effortLevel`, other hooks, ...) is left
untouched. `rtk-reinstall.sh` puts it all back later if you change your
mind.

## Usage

```bash
# Preview what would change, without touching anything
./rtk-uninstall.sh --dry-run

# Remove the rtk integration (backs up everything it touches first)
./rtk-uninstall.sh

# Bring it all back later
./rtk-reinstall.sh
```

Both scripts are idempotent — safe to run more than once.

### `rtk-uninstall.sh`

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

### `rtk-reinstall.sh`

Self-contained — it doesn't depend on the backups still existing. It
recreates `RTK.md` and the hook script from scratch, merges the hook
back into `settings.json` and the import back into `CLAUDE.md`
(additively, so it won't clobber other changes you've made to either
file since uninstalling), and reinstalls the binary — using the
snapshot `rtk-uninstall.sh` recorded if one is found, or the latest
release otherwise. Pass `--latest` to always grab the newest version.

## Requirements

- `bash`, `jq`
- `cargo` (only needed by `rtk-reinstall.sh`, and by `rtk-uninstall.sh`
  if `rtk` was installed via cargo)

## Configuration

Set `CLAUDE_DIR` in the environment if your Claude Code config doesn't
live at the default `~/.claude`:

```bash
CLAUDE_DIR=/path/to/.claude ./rtk-uninstall.sh
```

## Not affiliated with rtk-ai/rtk

This is an independent convenience toolkit for people already using
[rtk-ai/rtk](https://github.com/rtk-ai/rtk). It doesn't modify rtk
itself — just the Claude Code hook wiring around it.

## License

MIT — see [LICENSE](LICENSE).
