#!/usr/bin/env bash
# Checks the size of every contract and library built from contracts/, against EIP-170 (runtime code) and
# EIP-3860 (init code).
#
# `forge build --sizes` leaves some contracts out of its table, among them a linked library whose external
# functions all take `storage` parameters (its ABI has no function). Such a library was never checked: it could
# pass CI and then fail to deploy. This script reads the build output itself and checks every contract.
#
# Run it after `forge build`. It prints every contract with its sizes, largest first, and fails if one is over
# a limit.
set -euo pipefail

RUNTIME_CODE_LIMIT=24576 # EIP-170, in bytes
INIT_CODE_LIMIT=49152    # EIP-3860, in bytes
BUILD_OUTPUT_FOLDER="${1:-out}"

sizeLines=""
overLimitCount=0

for artifactFile in "$BUILD_OUTPUT_FOLDER"/*.sol/*.json; do
    # Only contracts whose source is under contracts/ (not dependencies, tests or scripts).
    sourcePath=$(jq -r '.metadata.settings.compilationTarget // {} | keys[0] // ""' "$artifactFile")
    if [[ "$sourcePath" != contracts/* ]]; then
        continue
    fi

    contractName=$(basename "$artifactFile" .json)
    runtimeCode=$(jq -r '.deployedBytecode.object // "0x"' "$artifactFile")
    initCode=$(jq -r '.bytecode.object // "0x"' "$artifactFile")

    # The code is a hex string that starts with "0x": two characters per byte.
    runtimeSize=$(((${#runtimeCode} - 2) / 2))
    initSize=$(((${#initCode} - 2) / 2))

    # Interfaces and abstract contracts have no code.
    if [[ "$runtimeSize" -eq 0 ]]; then
        continue
    fi

    runtimeMargin=$((RUNTIME_CODE_LIMIT - runtimeSize))
    sizeLines+="$runtimeSize $contractName runtime $runtimeSize B ($runtimeMargin B left), init $initSize B"$'\n'

    if [[ "$runtimeSize" -gt "$RUNTIME_CODE_LIMIT" ]]; then
        sizeLines+="$runtimeSize OVER THE LIMIT: $contractName runtime code (limit $RUNTIME_CODE_LIMIT B)"$'\n'
        overLimitCount=$((overLimitCount + 1))
    fi
    if [[ "$initSize" -gt "$INIT_CODE_LIMIT" ]]; then
        sizeLines+="$runtimeSize OVER THE LIMIT: $contractName init code (limit $INIT_CODE_LIMIT B)"$'\n'
        overLimitCount=$((overLimitCount + 1))
    fi
done

if [[ -z "$sizeLines" ]]; then
    echo "No contract from contracts/ found in $BUILD_OUTPUT_FOLDER: run forge build first."
    exit 1
fi

# Each line starts with its runtime size so it can be sorted; the size is cut off before printing.
printf "%s" "$sizeLines" | sort -rn | cut -d' ' -f2-

if [[ "$overLimitCount" -gt 0 ]]; then
    exit 1
fi
