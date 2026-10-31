# Pushed main with passing checks; the `rx -d` session on contabo is gone (live sync still running)
cd "$WORK" || exit 1
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
g init; echo a > a.txt; g add a.txt; g commit -m init
s="$HOME/.cache/claude-statusline/state"; mkdir -p "$s" "$HOME/.cache/rx"
key="${WORK}|main"; key=${key//[^A-Za-z0-9._-]/_}
printf 'SUCCESS\t\n' > "$s/ci-$key"; echo "$STATUSLINE_NOW" > "$s/ci-$key.at"
echo down > "$s/rx-work"; echo "$STATUSLINE_NOW" > "$s/rx-work.at"
echo "$PPID" > "$HOME/.cache/rx/work.watch.pid"  # the test runner outlives the render
