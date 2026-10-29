#!/usr/bin/env bash
# Runs scripts/SeedInterop.s.sol against the selected network: the Gold Token's cross-chain
# flows on one chain, through a loopback gateway. Requires seed-gold.sh to have run against the
# same deployment. Re-run anytime; the infrastructure steps are idempotent and the movements run
# once unless INTEROP_FORCE_MOVEMENTS=true (see the script's header comment).
#
# Network selection (all optional; defaults reproduce the Base Sepolia seed):
#   NETWORK_NAME  record file name, e.g. baseSepolia | trexTestnet   (default baseSepolia)
#   RPC_URL       URL or foundry.toml alias passed to --rpc-url       (default baseSepolia)
#   FORGE_SCRIPT_ARGS  more forge-script flags
#   SATELLITE_CHAIN_ID chain id the loopback gateway attributes messages to (default 31338)
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

[ -f .env ] && { set -a; source .env; set +a; }

: "${DEPLOYER_PRIVATE_KEY:?set in .env — see .env.example}"
export NETWORK_NAME="${NETWORK_NAME:-baseSepolia}"
RPC_URL="${RPC_URL:-baseSepolia}"

RECORD="deployments/$NETWORK_NAME.json"
[ -f "$RECORD" ] || { echo "ERROR: $RECORD missing. Run deploy-and-record.sh first." >&2; exit 1; }
if [ -z "${ONCHAINID_IDENTITY_FACTORY:-}" ]; then
    ONCHAINID_RECORD="${ONCHAINID_DEPLOYMENTS_DIR:-../ONCHAINID/deployments}/$NETWORK_NAME.json"
    [ -f "$ONCHAINID_RECORD" ] || { echo "ERROR: ONCHAINID_IDENTITY_FACTORY not set and $ONCHAINID_RECORD missing." >&2; exit 1; }
    export ONCHAINID_IDENTITY_FACTORY=$(python3 -c 'import json; print(json.load(open("'"$ONCHAINID_RECORD"'"))["identityFactory"])')
fi
export TREX_FACTORY="${TREX_FACTORY:-$(python3 -c 'import json; print(json.load(open("'"$RECORD"'"))["trexFactory"])')}"
export TRUSTED_GATEWAY_REGISTRY="${TRUSTED_GATEWAY_REGISTRY:-$(python3 -c 'import json; print(json.load(open("'"$RECORD"'"))["trustedGatewayRegistry"])')}"
echo "NETWORK_NAME=$NETWORK_NAME"
echo "ONCHAINID_IDENTITY_FACTORY=$ONCHAINID_IDENTITY_FACTORY"
echo "TREX_FACTORY=$TREX_FACTORY"
echo "TRUSTED_GATEWAY_REGISTRY=$TRUSTED_GATEWAY_REGISTRY"

mkdir -p deployments

# --slow sends one transaction at a time, waiting for each receipt before the next.
# Required here: the deployer EOA has an EIP-7702 delegation and Base Sepolia rejects
# pipelined nonces from delegated accounts.
# shellcheck disable=SC2086
forge script scripts/SeedInterop.s.sol --rpc-url "$RPC_URL" --broadcast --slow ${VERIFY_ARGS:-} ${FORGE_SCRIPT_ARGS:-}
