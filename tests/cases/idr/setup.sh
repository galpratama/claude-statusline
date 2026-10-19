# Rupiah display with a cached rate of Rp16.543,21 per USD
c="$HOME/.claude/statusline-config.json"
jq '.display.currency = "idr"' "$c" > "$c.tmp" && mv "$c.tmp" "$c"
mkdir -p "$HOME/.cache/claude-statusline"
printf '%s\n%s\n' "$STATUSLINE_NOW" 1654321 > "$HOME/.cache/claude-statusline/usd-idr"
