#!/usr/bin/env bash
# Runs scripts/SeedGoldToken.s.sol against the selected network. Requires scripts/SeedActivity.s.sol
# to have already run against the same deployment (it reuses that script's claimIssuer0 - see
# SeedGoldToken.s.sol's header comment). Re-run anytime — suite/identity creation is idempotent,
# the scripted trades just add more activity each time (see that script's header comment).
#
# Network selection (all optional; defaults reproduce the Base Sepolia seed):
#   NETWORK_NAME  record file name, e.g. baseSepolia | trexTestnet   (default baseSepolia)
#   RPC_URL       URL or foundry.toml alias passed to --rpc-url       (default baseSepolia)
#   FORGE_SCRIPT_ARGS  more forge-script flags, e.g. "--code-size-limit 49152" on Osaka chains
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

[ -f .env ] && { set -a; source .env; set +a; }

: "${DEPLOYER_PRIVATE_KEY:?set in .env — see .env.example}"
export NETWORK_NAME="${NETWORK_NAME:-baseSepolia}"
RPC_URL="${RPC_URL:-baseSepolia}"

if [ -z "${ONCHAINID_IDENTITY_FACTORY:-}" ]; then
    RECORD="${ONCHAINID_DEPLOYMENTS_DIR:-../ONCHAINID/deployments}/$NETWORK_NAME.json"
    [ -f "$RECORD" ] || { echo "ERROR: ONCHAINID_IDENTITY_FACTORY not set and $RECORD missing." >&2; exit 1; }
    export ONCHAINID_IDENTITY_FACTORY=$(python3 -c 'import json; print(json.load(open("'"$RECORD"'"))["identityFactory"])')
fi
if [ -z "${TREX_FACTORY:-}" ]; then
    RECORD="deployments/$NETWORK_NAME.json"
    [ -f "$RECORD" ] || { echo "ERROR: TREX_FACTORY not set and $RECORD missing. Run deploy-and-record.sh first." >&2; exit 1; }
    export TREX_FACTORY=$(python3 -c 'import json; print(json.load(open("'"$RECORD"'"))["trexFactory"])')
fi
echo "NETWORK_NAME=$NETWORK_NAME"
echo "ONCHAINID_IDENTITY_FACTORY=$ONCHAINID_IDENTITY_FACTORY"
echo "TREX_FACTORY=$TREX_FACTORY"

# vm.writeLine doesn't create parent directories.
mkdir -p deployments
mkdir -p "${ONCHAINID_DEPLOYMENTS_DIR:-../ONCHAINID/deployments}"

# --slow sends one transaction at a time, waiting for each receipt before the next.
# Required here: the deployer EOA has an EIP-7702 delegation and Base Sepolia rejects
# pipelined nonces from delegated accounts.

forge script scripts/SeedGoldToken.s.sol --rpc-url "$RPC_URL" --broadcast --slow ${FORGE_SCRIPT_ARGS:-}
