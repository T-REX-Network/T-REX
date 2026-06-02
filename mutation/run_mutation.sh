#!/usr/bin/env bash
#
# Gambit mutation-testing runner for T-REX (two-pass).
#
# Gambit (mutation/gambit_conf.json) generates source mutants under
# gambit_out/mutants/<id>/. This script applies each mutant in turn and runs the
# Foundry test suite, classifying each as:
#
#   KILLED    - the suite failed to compile or a test failed (mutant detected)
#   SURVIVED  - the suite still passes with the mutant applied (test gap!)
#   TIMEOUT   - the suite exceeded MUT_TIMEOUT (counted as killed for scoring)
#
# Two passes keep wall-clock low without sacrificing kill power:
#   PASS 1  applies every mutant against the fast *deterministic* Token suite
#           (unit + integration, ~0.6s each) — kills most mutants cheaply.
#   PASS 2  re-runs only the PASS-1 survivors against the full suite that adds the
#           randomized fuzz + stateful invariant harnesses — catches the arithmetic /
#           state mutants the example-based tests miss.
#
# Mutation score = (KILLED + TIMEOUT) / total scored.
#
# Usage:   mutation/run_mutation.sh [--limit N] [--start ID]
# Env:     MUT_TIMEOUT (per-mutant seconds, default 180)
#
# RESULTS_DIR lives OUTSIDE cache/ on purpose: Foundry manages cache/ and wiped
# the previous runner + results mid-run. .audit-cache/ is never touched by forge.
#
# Portable to macOS bash 3.2 (no mapfile); timeout via Perl alarm.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MUTANTS_DIR="gambit_out/mutants"
RESULTS_DIR=".audit-cache/mutation-results"
TARGET="contracts/token/Token.sol"
BACKUP="$(mktemp)"
TIMEOUT_S="${MUT_TIMEOUT:-180}"

# Fast deterministic Token tests (pass 1) and the full randomized suite (pass 2).
FAST_TESTS='test/{unit,integration}/token/*'
FULL_TESTS='test/{unit,integration,fuzz,invariant}/**/*.sol'

mkdir -p "$RESULTS_DIR"
CSV="$RESULTS_DIR/mutation_results.csv"
LOG="$RESULTS_DIR/run.log"

cp "$TARGET" "$BACKUP"
restore() { [[ -f "$BACKUP" ]] && cp "$BACKUP" "$TARGET"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM

LIMIT=0
START=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --start) START="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

# Perl alarm = portable `timeout`: SIGALRM kills the child -> exit 142.
run_tests() { # $1 = test glob
  FOUNDRY_PROFILE=mutation perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' \
    "$TIMEOUT_S" forge test --match-path "$1" >/dev/null 2>&1
}

meta_for() { # $1 = id -> "op|line"
  awk -F, -v i="$1" '$1==i {print $2"|"$4; exit}' gambit_out/mutants.log
}

apply_and_run() { # $1 = id, $2 = test glob ; echoes status, sets $rc
  cp "$MUTANTS_DIR/$1/$TARGET" "$TARGET"
  run_tests "$2"; rc=$?
  cp "$BACKUP" "$TARGET"
  if [[ $rc -eq 142 ]]; then echo "TIMEOUT";
  elif [[ $rc -eq 0 ]]; then echo "SURVIVED";
  else echo "KILLED"; fi
}

: > "$LOG"
IDS=$(ls "$MUTANTS_DIR" | sort -n)
TOTAL=$(echo "$IDS" | wc -w | tr -d ' ')

echo "Two-pass mutation run over $TOTAL mutants (timeout ${TIMEOUT_S}s, profile=mutation)" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# PASS 1 — fast deterministic suite over every mutant
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"; echo "=== PASS 1: $FAST_TESTS ===" | tee -a "$LOG"
SURVIVORS=""
killed=0; survived=0; timedout=0; processed=0
for id in $IDS; do
  [[ "$id" -lt "$START" ]] && continue
  if [[ "$LIMIT" -gt 0 && "$processed" -ge "$LIMIT" ]]; then break; fi
  [[ -f "$MUTANTS_DIR/$id/$TARGET" ]] || { echo "$id: no mutant, skip" | tee -a "$LOG"; continue; }
  meta=$(meta_for "$id"); op="${meta%%|*}"; line="${meta##*|}"
  status=$(apply_and_run "$id" "$FAST_TESTS")
  case "$status" in
    TIMEOUT)  timedout=$((timedout+1)) ;;
    SURVIVED) survived=$((survived+1)); SURVIVORS="$SURVIVORS $id" ;;
    KILLED)   killed=$((killed+1)) ;;
  esac
  processed=$((processed+1))
  printf '%3d/%d  m%-4s %-28s %-12s -> %s\n' "$processed" "$TOTAL" "$id" "$op" "$line" "$status" | tee -a "$LOG"
done
echo "PASS 1: killed=$killed survived=$survived timeout=$timedout" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# PASS 2 — full randomized suite over PASS-1 survivors only
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"; echo "=== PASS 2 (survivors): $FULL_TESTS ===" | tee -a "$LOG"
# id -> final status / which pass killed it
declare -a FINAL_ID FINAL_OP FINAL_LINE FINAL_STATUS FINAL_PASS
idx=0
# Re-walk in order to keep the CSV sorted; re-derive pass-1 status from SURVIVORS membership.
killed2=0
for id in $IDS; do
  [[ "$id" -lt "$START" ]] && continue
  [[ -f "$MUTANTS_DIR/$id/$TARGET" ]] || continue
  if [[ "$LIMIT" -gt 0 && "$idx" -ge "$LIMIT" ]]; then break; fi
  meta=$(meta_for "$id"); op="${meta%%|*}"; line="${meta##*|}"
  if echo " $SURVIVORS " | grep -q " $id "; then
    status=$(apply_and_run "$id" "$FULL_TESTS")
    if [[ "$status" == "SURVIVED" ]]; then pass="-"; else killed2=$((killed2+1)); pass="2"; fi
    printf '   m%-4s %-28s %-12s pass1=SURVIVED pass2=%s\n' "$id" "$op" "$line" "$status" | tee -a "$LOG"
  else
    status="KILLED"; pass="1"
  fi
  FINAL_ID[$idx]="$id"; FINAL_OP[$idx]="$op"; FINAL_LINE[$idx]="$line"
  FINAL_STATUS[$idx]="$status"; FINAL_PASS[$idx]="$pass"
  idx=$((idx+1))
done

# ---------------------------------------------------------------------------
# Emit CSV + summary
# ---------------------------------------------------------------------------
echo "id,operator,line,status,killed_by_pass" > "$CSV"
fk=0; fs=0; ft=0
for ((i=0; i<idx; i++)); do
  echo "${FINAL_ID[$i]},${FINAL_OP[$i]},${FINAL_LINE[$i]},${FINAL_STATUS[$i]},${FINAL_PASS[$i]}" >> "$CSV"
  case "${FINAL_STATUS[$i]}" in
    KILLED)   fk=$((fk+1)) ;;
    SURVIVED) fs=$((fs+1)) ;;
    TIMEOUT)  ft=$((ft+1)) ;;
  esac
done

{
  echo ""
  echo "==== Mutation summary ===="
  echo "total scored : $idx"
  echo "killed       : $fk  (pass1=$((fk-killed2)), pass2=$killed2)"
  echo "survived     : $fs"
  echo "timeout      : $ft  (counted as killed for scoring)"
  if [[ $idx -gt 0 ]]; then
    awk -v k="$fk" -v t="$ft" -v s="$fs" \
      'BEGIN{printf "score        : %.1f%% ((%d killed + %d timeout)/%d)\n",100*(k+t)/(k+t+s),k,t,k+t+s}'
  fi
  echo ""
  echo "Survivors (test gaps):"
  for ((i=0; i<idx; i++)); do
    [[ "${FINAL_STATUS[$i]}" == "SURVIVED" ]] && echo "  m${FINAL_ID[$i]}  ${FINAL_OP[$i]}  @${FINAL_LINE[$i]}"
  done
} | tee -a "$LOG"
