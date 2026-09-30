#!/bin/bash
# Fails when a contract under contracts/ exceeds EIP-170 (runtime) or EIP-3860 (initcode).
# Usage, after forge build: .github/scripts/check_contract_sizes.sh [out-dir]
set -euo pipefail

OUT_DIR="${1:-out}"
RUNTIME_LIMIT=24576
INITCODE_LIMIT=49152
HEADROOM_WARNING=512

if [ ! -d "$OUT_DIR" ]; then
    echo "❌ $OUT_DIR not found. Run 'forge build' first."
    exit 1
fi

ROWS=$(find "$OUT_DIR" -name '*.json' -not -path '*/build-info/*' -print0 | xargs -0 jq -r '
    select(.metadata.settings.compilationTarget != null)
    | (.metadata.settings.compilationTarget | to_entries[0]) as $target
    | select($target.key | startswith("contracts/"))
    | ((.deployedBytecode.object // "0x" | ltrimstr("0x") | length) / 2) as $runtime
    | ((.bytecode.object // "0x" | ltrimstr("0x") | length) / 2) as $init
    | select($runtime > 0)
    | "\($runtime) \($init) \(input_filename | split("/") | last | rtrimstr(".json")) \($target.key)"
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
    printf "%-34s %10s %10s %10s %s\n" "$name" "$runtime" "$margin" "$init" "$status"
done < <(echo "$ROWS" | head -10; echo "$ROWS" | tail -n +11 | awk -v limit="$RUNTIME_LIMIT" -v warn="$HEADROOM_WARNING" -v initlimit="$INITCODE_LIMIT" '$1 > limit - warn || $2 > initlimit')
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
