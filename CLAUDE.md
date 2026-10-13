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

- `load_config` - all segment toggles in one `jq` call over `~/.claude/statusline-config.json`
- `parse_transcript` - only `tool_use` lines are JSON-parsed; `tool_result` IDs are pulled by regex (tool output is most of a transcript's bytes). Uses `rg` via `_tsearch` when available, BSD grep is ~20x slower on big transcripts
- Subagents: `Agent` (and legacy `Task`) tool uses. Background agents get an immediate "Async agent launched" result and count as running until a `<task-notification>` with their `<tool-use-id>` appears
- `get_git_info` / `get_git_metrics` - one `git status --porcelain=v2 --branch` plus `log -1` and `rev-list --count --since=midnight`
- `format_rate_limits`, `format_prompt_cache` - render `.rate_limits` and `.prompt_cache` from the input
- `calculate_cost` - only used when the input has no `.cost.total_cost_usd`

### Input fields used

`model`, `effort.level`, `fast_mode`, `thinking.enabled`, `session_name`, `cost.*`, `context_window.*` (incl. `used_percentage`), `prompt_cache.{warm,hit_ratio,expires_at}`, `rate_limits.{five_hour,seven_day}`, `transcript_path`, `workspace.current_dir`.

Transcript timestamps are UTC; parse them with `TZ=UTC` (see `format_elapsed_time`).

## Testing

Test the statusline manually (capture a real input first by temporarily adding
`printf '%s' "$input" > /tmp/statusline-debug.json` after `input=$(cat)` in `main`):
```bash
bash ~/Scripts/claude-statusline/statusline-command.sh < /tmp/statusline-debug.json
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

The script creates temporary files for session tracking:
- `/tmp/claude-session-{session_id}` - Session start timestamp
- `/tmp/claude-metrics-{session_id}` - Token tracking
- `/tmp/claude-messages-{session_id}` - Message count
- `/tmp/claude-cache-{session_id}-*` - Cached expensive operations
