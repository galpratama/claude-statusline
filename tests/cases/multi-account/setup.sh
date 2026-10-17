# naira is active; azura has headroom, elara's window already reset, haila's 7d is exhausted
mkdir -p "$HOME/.claude-naira" "$HOME/.cache/claude-statusline"
printf '{"oauthAccount":{"emailAddress":"naira@example.com","organizationType":"claude_team","userRateLimitTier":"default_claude_max_5x"}}' > "$HOME/.claude-naira/.claude.json"
q="$HOME/.cache/claude-statusline"
echo "40 $((STATUSLINE_NOW + 9000)) 30 $((STATUSLINE_NOW + 400000))" > "$q/quota-azura.tsv"
echo "70 $((STATUSLINE_NOW - 60)) 30 $((STATUSLINE_NOW + 400000))" > "$q/quota-elara.tsv"
echo "5 $((STATUSLINE_NOW + 9000)) 95 $((STATUSLINE_NOW + 400000))" > "$q/quota-haila.tsv"
