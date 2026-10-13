#!/bin/bash
# Claude Code SessionStart hook: keep the Honcho plugin patched and prune stale per-session files.
# Prints nothing unless patch-honcho.py has something to report (plugin updated or a patch failed).

DIR="$(cd "$(dirname "$0")" && pwd)"
STALE_DAYS=7

python3 "$DIR/patch-honcho.py" --hook 2>/dev/null

# Deleted files go to the macOS Trash (never rm); skip pruning if `trash` isn't available
if command -v trash >/dev/null 2>&1; then
    find "$HOME/.honcho" -maxdepth 1 -type f \
        \( -name 'state-*.json' -o -name 'session-*.json' -o -name 'status-*.json' \) \
        -mtime +"$STALE_DAYS" -exec trash {} + 2>/dev/null
    find /tmp/ -maxdepth 1 -type f \
        \( -name 'claude-session-*' -o -name 'claude-metrics-*' -o -name 'claude-messages-*' \
           -o -name 'claude-stats-*' -o -name 'claude-transcript-result-*' \) \
        -mtime +"$STALE_DAYS" -exec trash {} + 2>/dev/null
fi

exit 0
