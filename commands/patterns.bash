# commands/patterns.bash — Show success/failure stats + cost tracking

cmd_patterns() {
  if [ ! -f "$PATTERNS_FILE" ] || [ ! -s "$PATTERNS_FILE" ]; then
    log "No pattern data yet. Complete some tasks first."
    return 0
  fi

  echo ""
  log "${BOLD}Last 20 entries:${NC}"
  echo ""
  printf "  %-30s %-10s %-20s %-5s %-7s %s\n" "TASK" "AGENT" "MODEL" "TRY" "OK?" "DURATION"
  printf "  %-30s %-10s %-20s %-5s %-7s %s\n" "----" "-----" "-----" "---" "---" "--------"

  tail -20 "$PATTERNS_FILE" | while IFS= read -r line; do
    local id agent model retries success duration
    id=$(echo "$line" | jq -r '.id')
    agent=$(echo "$line" | jq -r '.agent')
    model=$(echo "$line" | jq -r '.model')
    retries=$(echo "$line" | jq -r '.retries')
    success=$(echo "$line" | jq -r '.success')
    duration=$(echo "$line" | jq -r '.duration_s')

    local ok_str duration_str
    if [ "$success" = "true" ]; then
      ok_str="${GREEN}yes${NC}"
    else
      ok_str="${RED}no${NC}"
    fi
    duration_str="$((duration / 60))m"

    printf "  %-30s %-10s %-20s %-5s %-7b %s\n" "$id" "$agent" "$model" "$retries" "$ok_str" "$duration_str"
  done

  echo ""
  log "${BOLD}Stats by agent:${NC}"
  echo ""

  local total_entries success_entries
  total_entries=$(wc -l < "$PATTERNS_FILE" | tr -d ' ')
  success_entries=$(jq -s '[.[] | select(.success == true)] | length' "$PATTERNS_FILE")

  echo "  Overall: ${success_entries}/${total_entries} succeeded ($( [ "$total_entries" -gt 0 ] && echo "$((success_entries * 100 / total_entries))%" || echo "0%"))"
  echo ""

  # Per-agent stats
  for a in claude codex gemini; do
    local a_total a_success
    a_total=$(jq -s "[.[] | select(.agent == \"$a\")] | length" "$PATTERNS_FILE")
    if [ "$a_total" -gt 0 ]; then
      a_success=$(jq -s "[.[] | select(.agent == \"$a\" and .success == true)] | length" "$PATTERNS_FILE")
      local avg_retries
      avg_retries=$(jq -s "[.[] | select(.agent == \"$a\")] | (map(.retries) | add) / length | . * 10 | floor / 10" "$PATTERNS_FILE")
      # Cost tracking
      local total_cost cost_per_success
      total_cost=$(jq -s "[.[] | select(.agent == \"$a\")] | map(.estimated_cost_usd // \"0\" | tonumber) | add // 0 | . * 100 | floor / 100" "$PATTERNS_FILE" 2>/dev/null || echo "n/a")
      if [ "$a_success" -gt 0 ]; then
        cost_per_success=$(jq -s "[.[] | select(.agent == \"$a\")] | map(.estimated_cost_usd // \"0\" | tonumber) | add // 0 | . / $a_success | . * 100 | floor / 100" "$PATTERNS_FILE" 2>/dev/null || echo "n/a")
      else
        cost_per_success="n/a"
      fi
      echo "  ${a}: ${a_success}/${a_total} ($((a_success * 100 / a_total))%) | avg retries: ${avg_retries} | total: \$${total_cost} | \$/success: \$${cost_per_success}"
    fi
  done
  echo ""
}
