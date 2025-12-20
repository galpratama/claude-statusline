# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a custom statusline for Claude Code that displays AI model information, costs, git status, and development environment details. It's a bash-based solution that integrates with Claude Code's statusline feature.

## Architecture

### Core Files

- **statusline-command.sh** - Main script (~1475 lines) that generates the status display. Reads JSON input from stdin containing session data, processes it, and outputs formatted statusline text with ANSI colors.
- **statusline-config.json** - Configuration file controlling display segments, monitored ports, and subscription tracking.

### Data Flow

1. Claude Code pipes JSON session data to the statusline script via stdin
2. Script parses JSON using `jq` to extract: model info, token counts, costs, MCP servers, tools
3. Script detects local environment: git status, running servers, package managers, languages
4. Outputs 2-4 lines of formatted text with ANSI color codes

### Key Script Sections

- **Lines 17-70**: Configuration loading from JSON with defaults
- **Lines 80-97**: Color definitions (centralized)
- **Lines 100-137**: Caching utilities for expensive operations
- **Lines 140-320**: Input parsing and session tracking
- **Lines 325-415**: Language/package manager detection
- **Lines 433-519**: Server detection (netstat/lsof)
- **Lines 521-736**: Cost calculation with model-specific pricing
- **Lines 850-950**: Git information gathering
- **Lines 1080-1194**: Subscription expiration calculation

## Testing

Test the statusline manually:
```bash
bash ~/Scripts/claude-statusline/statusline-command.sh < /tmp/statusline-debug.json
```

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
- **git** - For git status (optional)
- **lsof** or **netstat** - For server detection
- **bc** - For cost calculations

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
