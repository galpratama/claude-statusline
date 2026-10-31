# auto, quiet: main is 2 commits ahead of its upstream and an `rx -d` server runs on :4241
cd "$WORK" || exit 1
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
g init --bare "$HOME/remote.git"; g init; echo a > a.txt; g add a.txt; g commit -m init
g remote add origin "$HOME/remote.git"; g push -u origin main
for i in 1 2; do echo "$i" >> a.txt; g commit -am "c$i"; done
s="$HOME/.cache/claude-statusline/state"; mkdir -p "$s" "$HOME/.cache/rx"
printf 'bash -lc cd ~/e2e/work && pnpm dev --port 4241\n' > "$s/rx-work"; echo "$STATUSLINE_NOW" > "$s/rx-work.at"
echo "$PPID" > "$HOME/.cache/rx/work.watch.pid"  # the test runner outlives the render
