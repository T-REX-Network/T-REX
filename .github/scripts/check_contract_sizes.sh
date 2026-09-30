#!/bin/bash
# Fails when a deployable contract under contracts/ is over the EVM's code-size limits:
# EIP-170 (24,576 bytes of runtime code) or EIP-3860 (49,152 bytes of init code).
#
# `forge build --sizes` cannot be the gate here: it also counts test harnesses, some of which
# inherit a production contract and are over the limit by design, so it would fail for the wrong
# reason. This reads the build artifacts instead and keeps only what is compiled from contracts/.
#
# Run after `forge build`. Usage: .github/scripts/check_contract_sizes.sh [out-dir]
set -euo pipefail

OUT_DIR="${1:-out}"
RUNTIME_LIMIT=24576
INITCODE_LIMIT=49152
# Warn before the wall is hit: a contract with less than this many bytes left cannot take a fix.
HEADROOM_WARNING=512

if [ ! -d "$OUT_DIR" ]; then
    echo "❌ $OUT_DIR not found. Run 'forge build' first."
    exit 1
fi

# One line per deployable contract compiled from contracts/: "<runtime> <initcode> <name> <source>".
# Interfaces and abstract contracts have no bytecode and are left out. Link placeholders have the
# length of the address they stand for, so an unlinked artifact measures the same as a linked one.
ROWS=$(find "$OUT_DIR" -name '*.json' -not -path '*/build-info/*' -print0 | xargs -0 jq -r '
    select(.metadata.settings.compilationTarget != null)
    | (.metadata.settings.compilationTarget | to_entries[0]) as $target
    | select($target.key | startswith("contracts/"))
    | ((.deployedBytecode.object // "0x" | ltrimstr("0x") | length) / 2) as $runtime
    | ((.bytecode.object // "0x" | ltrimstr("0x") | length) / 2) as $init
    | select($runtime > 0)
    | "\($runtime) \($init) \($target.value) \($target.key)"
' | sort -rn | uniq)

if [ -z "$ROWS" ]; then
    echo "❌ No contract artifacts from contracts/ found in $OUT_DIR"
    exit 1
fi

echo "=== Contract sizes (contracts/ only) ==="
printf "%-34s %10s %10s %10s\n" "Contract" "Runtime" "Margin" "Initcode"

FAILED=0
WARNED=0
while read -r runtime init name source; do
    margin=$((RUNTIME_LIMIT - runtime))
    status=""
    if [ "$runtime" -gt "$RUNTIME_LIMIT" ] || [ "$init" -gt "$INITCODE_LIMIT" ]; then
        status="❌"
        FAILED=1
    elif [ "$margin" -lt "$HEADROOM_WARNING" ]; then
        status="⚠️"
        WARNED=1
    fi
    # Only the contracts worth reading: the offenders, the near-misses and the ten largest.
    printf "%-34s %10s %10s %10s %s\n" "$name" "$runtime" "$margin" "$init" "$status"
done < <(echo "$ROWS" | head -10; echo "$ROWS" | tail -n +11 | awk -v limit="$RUNTIME_LIMIT" -v warn="$HEADROOM_WARNING" '$1 > limit - warn')
echo "========================================"

if [ "$WARNED" -eq 1 ]; then
    echo "⚠️  Less than $HEADROOM_WARNING bytes of headroom on at least one contract."
fi

if [ "$FAILED" -eq 1 ]; then
    echo "❌ At least one contract exceeds EIP-170 ($RUNTIME_LIMIT bytes runtime) or EIP-3860 ($INITCODE_LIMIT bytes initcode)."
    echo "   It cannot be deployed on Ethereum, Base, OP Stack, Arbitrum or any chain enforcing those limits."
    exit 1
fi

echo "✅ Every contract under contracts/ fits within EIP-170 and EIP-3860."
