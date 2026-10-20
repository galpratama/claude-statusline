# Ponytail band: level flag + ledger; an older row of the same session, another session, a name with commas
mkdir -p "$HOME/.claude" "$HOME/.config/ponytail/band"
printf 'ultra\n' > "$HOME/.claude/.ponytail-active"
cat > "$HOME/.config/ponytail/band/work.csv" <<'CSV'
key,started,project,name,cost_usd,turns,agent_minutes,tokens_total,tokens_output,reuse_pct,reused,new,callers_open,tests,level,model
abcd1234-1,2026-10-20 09:00,work,old,1.00,2,0.5,1000,100,,0,1,0,not run,full,
ffff0000-1,2026-10-20 09:00,work,other,9.00,9,9.9,9000,900,10,1,9,9,9 failed,lite,
abcd1234-2,2026-10-20 10:00,work,"fix, then ship",2.50,6,4.2,50000,3000,67,4,2,1,12 passed,ultra,claude-sonnet-5-5
CSV
