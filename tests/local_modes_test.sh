#!/bin/zsh
# Golden battery for the pure-code mode transforms. Every case pipes a real
# dictation shape through the installed binary's --local-mode hook and asserts
# properties of the output (contains / not-contains), so intentional wording
# changes don't shatter the suite but regressions do.
#
# Run: ./tests/local_modes_test.sh   (exits nonzero on any failure)

BIN="$HOME/.dictation/PttDictate.app/Contents/MacOS/ptt-dictate"
PASS=0; FAIL=0

check() {  # check <name> <mode> <input> <must-contain...> -- <must-not-contain...>
  local name=$1 mode=$2 input=$3; shift 3
  local out=$(print -r -- "$input" | "$BIN" --local-mode "$mode" 2>/dev/null)
  local neg=0 ok=1 why=""
  for pat in "$@"; do
    if [[ $pat == "--" ]]; then neg=1; continue; fi
    if (( neg == 0 )); then
      [[ $out == *"$pat"* ]] || { ok=0; why="missing '$pat'"; break; }
    else
      [[ $out != *"$pat"* ]] || { ok=0; why="should not contain '$pat'"; break; }
    fi
  done
  if (( ok )); then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1))
    print "FAIL [$name] $why"
    print "  in:  $input"
    print "  out: $out"
  fi
}

# ── Professional ────────────────────────────────────────────────────────────
check "filler+money" professional \
  "um so basically let them know the quote is ready, its gonna be 4500 dollars with the extra coverage and um we can start tuesday if they sign tonight" \
  '$4,500' -- "um " "basically"

check "self-correction" professional \
  "we can start tuesday no wait wednesday" \
  "wednesday" -- "tuesday"

check "question-mark" professional \
  "can you send me the updated file before five." \
  "before five?" -- "five.?"

check "wh-declarative-stays" professional \
  "What I want is the blue version." \
  "blue version." -- "version?"

check "greeting-signoff" professional \
  "Hey sarah. Quick update. The deploy went out this morning. Everything looks stable so far. Thanks so much." \
  "Hey Sarah," "Thanks so much."

check "double-words" professional \
  "we need to to check the the deploy" \
  "to check the deploy" -- "to to" "the the"

check "contractions" professional \
  "arent you coming, youll miss it, theyve already started" \
  "Aren't" "you'll" "they've"

check "trailing-throwaway" professional \
  "just clean up the imports and stuff like that." \
  "clean up the imports" -- "and stuff"

check "percent-time" professional \
  "conversion went up 35 percent since 9 am." \
  "35%" "9 AM"

check "paragraph-break" professional \
  "First point here. Second point here. Third point here. Fourth point here. Fifth point here." \
  "here.

"

# ── Summarize ───────────────────────────────────────────────────────────────
check "list-detect" summarize \
  "First, update the billing page. Then, test the webhook. Finally, ship it to production." \
  "- Update the billing page." "- Test the webhook." "- Ship it to production."

check "decisions-actions" summarize \
  "We decided to go with Railway for hosting. I need to update the docs tomorrow. The rest of the week is open for client work and nothing else changed." \
  "Decisions" "- We decided to go with Railway" "Action items" "- I need to update the docs tomorrow."

check "topic-shift" summarize \
  "The deploy finished fine and the numbers look good so far today. By the way, the invoice went out this morning to the client." \
  "invoice"

# ── Agent brief ─────────────────────────────────────────────────────────────
check "agent-4-sections" agent \
  "fix the login bug on the settings page, dont touch the signup flow, its done when the user can log back in after a password reset, the error is in auth.ts" \
  "Goal" "Constraints" "signup" "Done when" "log back in" "Context" "auth.ts"

check "agent-deadline-constraint" agent \
  "ship the new landing page by friday, keep it under 200 kilobytes total" \
  "Constraints" "by friday"

check "agent-new-goal-verbs" agent \
  "deploy the engine to the new host and migrate the config over" \
  "Goal"

# ── Expand ──────────────────────────────────────────────────────────────────
check "expand-performance" expand \
  "make the dashboard faster" \
  "fast enough"

check "expand-email" expand \
  "write an email to jeremy about the windows build" \
  "recipient"

check "expand-done-question" expand \
  "add a settings page" \
  "done look like"

# ── Fact guardrail ──────────────────────────────────────────────────────────
check "numbers-survive" agent \
  "raise the price to 4.99 and cap seats at 3, dont touch the 39 dollar annual plan" \
  "4.99" "3" "39"

print ""
print "===== $((PASS+FAIL)) checks: $PASS passed, $FAIL failed ====="
exit $(( FAIL > 0 ))
