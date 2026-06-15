# Changelog

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
