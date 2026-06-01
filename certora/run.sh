#!/usr/bin/env bash
# Fast-iteration Certora runner.
#   Usage: certora/run.sh Token          # runs confs/Token.conf
#          certora/run.sh ModularCompliance
#          certora/run.sh IdentityRegistry
#
# Blocks until the cloud job finishes (--wait_for_results all) and writes a
# plain-text, greppable result summary to .audit-cache/certora-<name>.result.txt
# so tooling (and Claude Code) can read PASS/VIOLATED without opening the web UI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export PATH="$HOME/.local/bin:$PATH"
# Load CERTORAKEY: prefer an already-exported value, else source repo-root .env.
if [ -z "${CERTORAKEY:-}" ]; then
  if [ -f ./.env ]; then set -a; source ./.env; set +a; fi
fi
[ -n "${CERTORAKEY:-}" ] || { echo "ERROR: CERTORAKEY not set (no env var and no ./.env). Set it or recreate .env." >&2; exit 2; }

name="${1:?usage: run.sh <ConfName e.g. Token>}"
conf="certora/confs/${name}.conf"
raw=".audit-cache/certora-${name}.raw.txt"     # full, noisy CLI output
out=".audit-cache/certora-${name}.result.txt"  # clean, greppable summary
mkdir -p .audit-cache

# certoraRun exits non-zero when rules are VIOLATED; that's a result, not a script
# error, so don't let pipefail/set -e abort before we write the summary.
set +e
certoraRun "$conf" --wait_for_results all --disable_local_typechecking 2>&1 \
  | tr '\r' '\n' | sed -E 's/\x1b\[[0-9;]*m//g' > "$raw"
rc=${PIPESTATUS[0]}
set -e

# Build the clean summary: drop spinner lines, keep verdicts + report URL.
{
  echo "================ CERTORA SUMMARY: $name (exit=$rc) ================"
  grep -ivE '^processing|^Output:|^$' "$raw" \
    | grep -iE '\[rule\]|\[invariant\]|VIOLAT|VERIFIED|PASS|FAIL|TIMEOUT|SANITY|violations|report url|anonymousKey|prover found' \
    || echo "(no verdict lines parsed — see $raw)"
} | tee "$out"
exit "$rc"
