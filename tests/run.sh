#!/bin/bash
# Snapshot tests: renders each tests/cases/<name>/input.json with a frozen clock and a fresh
# fake HOME, then compares the raw output (colors included) with expected.txt.
#   tests/run.sh            run all cases
#   tests/run.sh --update   rewrite expected.txt from the current output
#
# Case files: input.json (required; __WORK__ and __CASE__ are replaced with the case's
# working dir and own dir), env (KEY=VALUE lines, __HOME__ = the fake HOME), setup.sh
# (runs with HOME/WORK/STATUSLINE_NOW set), transcript.jsonl.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/statusline-command.sh"
UPDATE=""; [ "$1" = "--update" ] && UPDATE=1
NOW=1767225600  # 2026-01-01T00:00:00Z
# jq/git dirs go last: Windows keeps them outside the system dirs (WinGet\Links, /mingw64/bin)
TOOL_DIRS=""
for t in jq git; do p=$(command -v "$t") && TOOL_DIRS+=":${p%/*}"; done
pass=0; fail=0

strip() { perl -pe 's/\e\[[0-9;]*m//g'; }

for case_dir in "$ROOT"/tests/cases/*/; do
    case_dir=${case_dir%/}; name=${case_dir##*/}
    tmp=$(mktemp -d)
    home="$tmp/home"; work="$tmp/work"
    mkdir -p "$home/.claude" "$work"
    cp "$ROOT/tests/config.json" "$home/.claude/statusline-config.json"

    # Isolated environment; PATH keeps only system tools so docker/gh lookups are predictable
    env_args=(HOME="$home" WORK="$work" CASE="$case_dir" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin$TOOL_DIRS"
        TZ=UTC LC_ALL=en_US.UTF-8 COLUMNS=200 COLORTERM=truecolor STATUSLINE_NOW="$NOW")
    if [ -f "$case_dir/env" ]; then
        while IFS= read -r line; do [ -n "$line" ] && env_args+=("${line//__HOME__/$home}"); done < "$case_dir/env"
    fi
    [ -f "$case_dir/setup.sh" ] && env -i "${env_args[@]}" /bin/bash "$case_dir/setup.sh"

    sed -e "s|__WORK__|$work|g" -e "s|__CASE__|$case_dir|g" "$case_dir/input.json" > "$tmp/input.json"
    actual=$(env -i "${env_args[@]}" /bin/bash "$SCRIPT" < "$tmp/input.json" 2> "$tmp/stderr")
    # Paths differ per run; normalize them so snapshots are stable
    actual=${actual//$work/__WORK__}

    if [ -s "$tmp/stderr" ]; then
        echo "FAIL $name (stderr)"; sed 's/^/    /' "$tmp/stderr"; fail=$((fail + 1))
    elif [ -n "$UPDATE" ]; then
        printf '%s\n' "$actual" > "$case_dir/expected.txt"; echo "UPDATED $name"
    elif [ "$actual" = "$(cat "$case_dir/expected.txt" 2>/dev/null)" ]; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name"
        diff <(strip < "$case_dir/expected.txt") <(printf '%s\n' "$actual" | strip) | sed 's/^/    /'
        [ "$(strip < "$case_dir/expected.txt")" = "$(printf '%s\n' "$actual" | strip)" ] && echo "    (colors differ only)"
        fail=$((fail + 1))
    fi
    # Background refreshes (PR, servers) may still be writing into the fake HOME
    sleep 0.2
    command -v trash >/dev/null 2>&1 && trash "$tmp" 2>/dev/null
done

[ -n "$UPDATE" ] && exit 0
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
