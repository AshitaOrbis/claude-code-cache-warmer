# A full hit covers at least 80% of ALL input; callers may require more.
def counter:
  if type == "number" and . >= 0 and . == floor and . <= 9007199254740991
  then . else -1 end;
def usage_counters: [.cache_read, .cache_creation, .input_tokens] | map(counter);
def full_hit($threshold):
  usage_counters as $u | ($u | add) as $total |
  (.http | type == "number") and .http == 200 and
  $threshold >= 80 and $threshold <= 100 and
  $u[0] > 0 and $u[1] >= 0 and $u[2] >= 0 and $total > 0 and
  $u[0] * 100 >= $threshold * $total;
def capped_completion:
  (.cap | counter) as $cap | (.output_tokens | counter) as $out |
  $cap > 0 and $out >= 0 and $out <= $cap and
  ((has("aborted") | not) or .aborted == false);
