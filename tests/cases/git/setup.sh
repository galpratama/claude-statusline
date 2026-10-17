# Feature branch, last commit 5 minutes before the frozen clock, one stash, a modified and an untracked file
cd "$WORK" || exit 1
export GIT_AUTHOR_DATE="@$((STATUSLINE_NOW - 300)) +0000" GIT_COMMITTER_DATE="@$((STATUSLINE_NOW - 300)) +0000"
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
g init; echo a > a.txt; g add a.txt; g commit -m init; g checkout -b feat/refresh
echo b >> a.txt; g stash; echo c >> a.txt; echo new > new.txt
