# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a custom statusline for Claude Code that displays AI model information, costs, git status, and development environment details. It's a bash-based solution that integrates with Claude Code's statusline feature.

## Architecture

### Core Files

- **statusline-command.sh** - Main script that generates the status display. Reads JSON input from stdin containing session data, processes it, and outputs formatted statusline text with ANSI colors.
- **statusline-config.json** - Configuration file controlling display segments, monitored ports, and subscription tracking.

### Data Flow

1. Claude Code pipes JSON session data to the statusline script via stdin
2. `main()` reads every input field in ONE `jq` call (order of the `read` list must match the jq output list)
3. `parse_transcript()` scans the session JSONL for running tools, subagents, todos and completed-tool counts
4. Script detects local environment: git status, running servers, package managers, languages
5. Outputs 2-5 lines of formatted text with ANSI color codes

### Key Functions (find with `grep -n "^name() {"`)

Render path is fork-free where possible (a fork costs ~25ms in Git Bash on Windows, ~1ms on macOS): helpers set `REPLY` (or `GRAD`/`CAP`/`CFG_*`) instead of being called as `$(fn)`, files are read with `slurp`, external tools are called straight from `$(...)` so bash execs them in the substitution's fork. Avoid extglob patterns in `${var//...}`: bash 3.2 hangs on long strings.

- `load_config` - all segment toggles in one `jq` call over `~/.claude/statusline-config.json`
- `parse_transcript` - only `tool_use` lines are JSON-parsed; `tool_result` IDs are pulled by regex (tool output is most of a transcript's bytes). Uses `rg` via `TSEARCH` when available, BSD grep is ~20x slower on big transcripts. Its jq outputs render-ready lines to `$STATE_DIR/transcript-lines-*`, re-parsed only when the transcript is newer
- Subagents: `Agent` (and legacy `Task`) tool uses. Background agents get an immediate "Async agent launched" result and count as running until a `<task-notification>` with their `<tool-use-id>` appears
- `get_git_info` / `get_git_metrics` - one `git status --porcelain=v2 --branch --show-stash` (`branch<TAB>stash<TAB>info`) plus one `git log -n 100 --format=%ct` (last commit age + commits since local midnight)
- bash 3.2 gotcha: in `IFS=$'\t' read ... <<< "$(cmd)"` the IFS also applies inside `cmd`; capture into a variable first
- `grad_color` sets `GRAD` instead of printing (no subshell per bar cell)
- `format_ponytail_status` - ponytail level (`.ponytail-active` flag) plus reuse/callers/tests/agent time from the band ledger `~/.config/ponytail/band/*.csv`; trailing CSV columns are read from the end because the name column may hold quoted commas
- `format_rate_window`, `format_prompt_cache` - render `.rate_limits` (values come from the main jq call; run-out projection) and `.prompt_cache`
- `get_account_info` - account + plan from `$CLAUDE_CONFIG_DIR/.claude.json` (else `~/.claude.json`); `record_account_quota` / `suggest_account` share limits across accounts via `~/.cache/claude-statusline/quota-<account>.tsv`
- `grad_color` / `make_bar` - truecolor gradient + 1/8-cell bar (16-color fallback); `fit_line` - drops segments by priority to fit `$COLUMNS`. Lines 1-2 are built as `prio<TAB>sep<TAB>text` segments
- `sparkline` (history in `$STATE_DIR/hist-{session_id}`), `cost_ledger` (per-day spend in `~/.cache/claude-statusline/cost-YYYY-MM-DD.tsv`), `get_pr_status` (background `gh`, cache `$STATE_DIR/pr-<cache_key>`)
- Theme palette is resolved before the `readonly` color constants (`.display.theme` comes from the `load_config` jq)
- `bg_cached` - background-refreshed command cache (PR via `_fetch_pr`, docker), freshness stamp in `<cache>.at`; `fresh_cache`/`stamp_cache` - "epoch\nvalue" caches (`ver-*` tool versions, `sub-*` subscription); `notify_once` - osascript notification keyed by a flag in `$STATE_DIR/notified-*`
- Mode (`zen`/`compact`/`full`): `STATUSLINE_MODE` or `~/.cache/claude-statusline/mode`, set with `--mode`
- `calculate_cost` - only used when the input has no `.cost.total_cost_usd`
- Currency: `display.currency: "idr"` sets `RATE_IDR` (USD→IDR ×100) from `usd_idr_rate` (`~/.cache/claude-statusline/usd-idr`, hourly background `_fetch_usd_idr`); `fmt_cents`/`fmt_idr` format. Rate 0 (no cache yet) = USD
- Memory pressure: macOS only, one `sysctl kern.memorystatus_vm_pressure_level` per render, `⚠ RAM` at warn (2) / critical (4); `features.memory_pressure: false` turns it off (tests do)

### Input fields used

`model`, `effort.level`, `fast_mode`, `thinking.enabled`, `session_name`, `cost.*` (incl. `total_api_duration_ms` for burn rate), `context_window.*` (incl. `used_percentage`), `prompt_cache.{warm,hit_ratio,expires_at}`, `rate_limits.{five_hour,seven_day}`, `transcript_path`, `workspace.current_dir`.

Transcript timestamps are UTC; `parse_transcript` converts them to epochs in jq (`fromdateiso8601`).

## Testing

Snapshot tests (frozen clock via `STATUSLINE_NOW`, fresh fake HOME per case, system `jq` first in PATH so jq 1.7 compatibility is checked):
```bash
tests/run.sh            # compare with tests/cases/*/expected.txt
tests/run.sh --update   # accept the current output after an intended change
shellcheck -s bash statusline-command.sh session-start-hook.sh   # must stay clean
```
Add a case as `tests/cases/<name>/` with `input.json` and optionally `env`, `setup.sh`, `transcript.jsonl` (see the header of `tests/run.sh`).

Manual testing:

Test the statusline manually (capture a real input first by temporarily adding
`printf '%s' "$input" > /tmp/statusline-debug.json` after `input=$(cat)` in `main`):
```bash
bash ~/Scripts/claude-statusline/statusline-command.sh < /tmp/statusline-debug.json
```

Replaying a captured input with your real HOME pollutes the live session's state (cost ledger in `~/.cache/claude-statusline/`, `$STATE_DIR/hist-*`): the stale lower cost looks like a resume. Use a fake HOME and another session id:
```bash
jq '.session_id="test"' /tmp/statusline-debug.json | HOME=$(mktemp -d) bash statusline-command.sh
```

Time it with `/usr/bin/time -p`. Profile per line with
`PS4='+ $EPOCHREALTIME $LINENO ' /opt/homebrew/bin/bash -x statusline-command.sh < input.json 2> trace.txt`.

Or run directly (will use empty/default values):
```bash
bash ~/Scripts/claude-statusline/statusline-command.sh
```

## Configuration

The script looks for config in two locations:
1. `~/.claude/statusline-config.json` (for segment toggles)
2. `~/Scripts/claude-statusline/statusline-config.json` (for ports and subscriptions)

### Key Configuration Options

```json
{
  "features": {
    "server_detection": true,
    "listened_ports": [3000, 5173, 8000, 8080],
    "ignored_ports": [80]
  },
  "segments": {
    "ai": { "show_cost": true, "show_cache_efficiency": true },
    "git": { "enabled": true },
    "dev": { "show_running_servers": true }
  },
  "subscriptions": {
    "Claude": { "type": "monthly", "renewal_date": "2025-12-22" }
  }
}
```

## Dependencies

- **bash** - Standard bash shell
- **jq** - JSON processor (required)
- **rg** - ripgrep, optional but much faster transcript scanning
- **git** - For git status (optional)
- **lsof** or **netstat** - For server detection
- **bc** - Only for the fallback cost estimate

## Installation Path

The statusline is configured in `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "command": "/bin/bash $HOME/Scripts/claude-statusline/statusline-command.sh",
    "type": "command"
  }
}
```

## Session Files

All state lives in `STATE_DIR` = `~/.cache/claude-statusline/state/` (0700; not shared `/tmp`, where predictable names could be pre-created as symlinks by another user). `session-start-hook.sh` prunes files older than 7 days (and legacy `/tmp/claude-*` files):
- `session-*`, `metrics-*`, `messages-*`, `stats-*` - per-session start time, token total, message count, stats
- `ctxgrowth-*`, `hist-*` - context growth average and per-message history (sparklines)
- `transcript-result-*` - parsed transcript summary
- `account-*`, `pr-*`, `servers-*`, `docker`, `notified-*` - caches and notification flags

Shared across sessions in `~/.cache/claude-statusline/`: `cost-YYYY-MM-DD.tsv` (spend ledger), `quota-<account>.tsv` (last-seen limits), `mode`.
