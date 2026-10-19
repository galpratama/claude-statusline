#!/bin/bash
# Claude Code SessionStart hook: keep the Honcho plugin patched and prune stale per-session files.
# Prints nothing unless patch-honcho.py has something to report (plugin updated or a patch failed).

DIR="$(cd "$(dirname "$0")" && pwd)"
STALE_DAYS=7

# Windows' python3 is a Microsoft Store stub that only prints an install hint
PY=python3; "$PY" -c '' 2>/dev/null || PY=python
"$PY" "$DIR/patch-honcho.py" --hook 2>/dev/null

# Deleted files go to the macOS Trash (never rm); skip pruning if `trash` isn't available
if command -v trash >/dev/null 2>&1; then
    find "$HOME/.honcho" -maxdepth 1 -type f \
        \( -name 'state-*.json' -o -name 'session-*.json' -o -name 'status-*.json' \) \
        -mtime +"$STALE_DAYS" -exec trash {} + 2>/dev/null
    # Statusline state; /tmp holds files from versions before STATE_DIR
    find "$HOME/.cache/claude-statusline/state" -maxdepth 1 -type f -mtime +"$STALE_DAYS" -exec trash {} + 2>/dev/null
    find /tmp/ -maxdepth 1 -type f -user "$(id -u)" \
        \( -name 'claude-session-*' -o -name 'claude-metrics-*' -o -name 'claude-messages-*' \
           -o -name 'claude-stats-*' -o -name 'claude-transcript-result-*' -o -name 'claude-hist-*' \
           -o -name 'claude-ctxgrowth-*' -o -name 'claude-statusline-*' \) \
        -mtime +"$STALE_DAYS" -exec trash {} + 2>/dev/null
fi

exit 0
