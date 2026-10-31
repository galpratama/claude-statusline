# Pushed main whose checks failed (Vercel), and a live `rx -d` session serving on :4241
cd "$WORK" || exit 1
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
g init; echo a > a.txt; g add a.txt; g commit -m init
s="$HOME/.cache/claude-statusline/state"; mkdir -p "$s" "$HOME/.cache/rx"
key="${WORK}|main"; key=${key//[^A-Za-z0-9._-]/_}
printf 'FAILURE\tVercel\n' > "$s/ci-$key"; echo "$STATUSLINE_NOW" > "$s/ci-$key.at"
printf 'bash -lc cd ~/e2e/work && pnpm dev --hostname 100.82.35.25 --port 4241\n' > "$s/rx-work"; echo "$STATUSLINE_NOW" > "$s/rx-work.at"
echo "$PPID" > "$HOME/.cache/rx/work.watch.pid"  # the test runner outlives the render
