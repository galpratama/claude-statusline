# Changelog

## 2026-10-17 — Sparklines, spend ledger, PR status, themes
- Sparklines: cost per message + context trend
- `today $X wk $Y` spend across sessions (per-day ledger, midnight-split, resume-safe)
- Open PR + CI/review via background `gh` (open PRs only); OSC 8 links for folder/branch/PR
- Theme presets: catppuccin, tokyonight, dracula, nord, rosepine
- Burn rate now per active API hour (`total_api_duration_ms`)
- Fix: `vis_len` ignored raw ESC codes from `get_git_info`, overcounting line 2 width
- New demo.png

## 2026-10-17 — Visual + predictive statusline
- Truecolor gradient bars (1/8-cell precision) for context and 5h/7d limits; 16-color fallback (`STATUSLINE_TRUECOLOR=0`)
- Burn rate `$/h`, rate-limit run-out projection (`→ full ~HH:MM`), `~N msg left` before context fills
- Alerts: ctx ≥85%, cache <5m, limit ≥90% or projected run-out → bold `⚠` + red gutter
- Adaptive layout: `fit_line` drops low-priority segments to fit `$COLUMNS`
- Removed `format_rate_limits` (inlined as separate segments)


## 2026-06-15 — Claude usage (rate limits) segment

Added a Claude usage display showing the 5-hour and 7-day (weekly) subscription
rate limits on line 1 of the statusline, after the token/context section.

- Reads `rate_limits.five_hour` and `rate_limits.seven_day` from the statusline
  stdin JSON (provided by Claude Code for Pro/Max subscribers after the first API
  response in a session).
- Format: `◴ 5h 42% (2h15m) · 7d 88% (84h)`
  - Percentage colored green (<70%), yellow (70–89%), red (≥90%) — matching the
    context-usage thresholds.
  - `(<countdown>)` shows time until each window resets, derived from `resets_at`
    via the existing `format_duration` helper.
- Each window is independently optional; the segment is omitted entirely when no
  rate-limit data is present (non-subscribers / before the first API response).
- Gated behind the existing `segments.ai.show_rate_limit` config toggle (was a
  defined-but-unused placeholder; now implemented).

New functions in `statusline-command.sh`: `format_rate_window`, `format_rate_limits`.

### Follow-ups (same day)

- Context section now shows token figures alongside the percentage:
  `87% ctx (175k/200k)` (used / context-window size).
- Reworked rate-limit reset indicator from `⟳<countdown>` to `(<countdown>)` to
  remove the cluttered/overlapping glyphs between the 5h and 7d windows.
- Fixed a pre-existing `format_k` bug where whole thousands/millions lost a
  trailing zero (e.g. `200000` → `20k` instead of `200k`). The trailing-zero
  strip now only applies after a decimal point.
- Removed the `↑ <input> ↓ <output>` token counters from line 1 — now redundant
  with the `N% ctx (used/total)` figures. The context section is omitted (no
  dangling separator) when usage data isn't available yet.
