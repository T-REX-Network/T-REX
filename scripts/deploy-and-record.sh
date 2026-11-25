#!/usr/bin/env bash
# Deploys the T-REX factory stack and records every address to deployments/<NETWORK_NAME>.json.
# Requires .env with DEPLOYER_PRIVATE_KEY and ONCHAINID_IDENTITY_FACTORY (see .env.example).
# ONCHAINID_IDENTITY_FACTORY defaults to $ONCHAINID_DEPLOYMENTS_DIR/<NETWORK_NAME>.json
# if not set explicitly.
#
# Network selection (all optional; defaults reproduce the Base Sepolia deploy):
#   NETWORK_NAME  record file name, e.g. baseSepolia | trexTestnet      (default baseSepolia)
#   CHAIN_ID      chain id, used to locate the Foundry broadcast file   (default: read from RPC_URL)
#   RPC_URL       URL or foundry.toml alias passed to --rpc-url          (default baseSepolia,
#                 which needs ALCHEMY_KEY)
#   VERIFY_ARGS   extra forge-script flags, e.g. "--verify"              (default --verify on
#                 Base Sepolia, empty elsewhere)
#   FORGE_SCRIPT_ARGS  more forge-script flags, e.g. "--code-size-limit 49152" on Osaka chains
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
[ -f .env ] && { set -a; source .env; set +a; }
: "${DEPLOYER_PRIVATE_KEY:?set in .env}"

NETWORK_NAME="${NETWORK_NAME:-baseSepolia}"
RPC_URL="${RPC_URL:-baseSepolia}"
CHAIN_ID="${CHAIN_ID:-$(cast chain-id --rpc-url "$RPC_URL")}"
if [ "$RPC_URL" = "baseSepolia" ]; then
    : "${ALCHEMY_KEY:?set in .env (backs the baseSepolia alias in foundry.toml)}"
fi
if [ -z "${VERIFY_ARGS+x}" ]; then
    if [ "$NETWORK_NAME" = "baseSepolia" ]; then VERIFY_ARGS="--verify"; else VERIFY_ARGS=""; fi
fi

if [ -z "${ONCHAINID_IDENTITY_FACTORY:-}" ]; then
    ONCHAINID_RECORD="${ONCHAINID_DEPLOYMENTS_DIR:-../ONCHAINID/deployments}/$NETWORK_NAME.json"
    [ -f "$ONCHAINID_RECORD" ] || { echo "ERROR: ONCHAINID_IDENTITY_FACTORY not set and $ONCHAINID_RECORD missing. Deploy ONCHAINID first." >&2; exit 1; }
    export ONCHAINID_IDENTITY_FACTORY=$(python3 -c 'import json; print(json.load(open("'"$ONCHAINID_RECORD"'"))["identityFactory"])')
fi
echo "Using ONCHAINID IdentityFactory: $ONCHAINID_IDENTITY_FACTORY"

echo "Deploying T-REX to $NETWORK_NAME (chain $CHAIN_ID) via $RPC_URL..."
# --slow sends one transaction at a time, waiting for each receipt before the next.
# Required here: the deployer EOA has an EIP-7702 delegation and Base Sepolia rejects
# pipelined nonces from delegated accounts.

# shellcheck disable=SC2086
forge script scripts/DeployTREX.s.sol --rpc-url "$RPC_URL" --broadcast --slow $VERIFY_ARGS ${FORGE_SCRIPT_ARGS:-}

RUN="broadcast/DeployTREX.s.sol/$CHAIN_ID/run-latest.json"

addr_for() {
    python3 -c '
import json, sys
name, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
for tx in d["transactions"]:
    if tx.get("contractName") == name and tx.get("transactionType") == "CREATE":
        print(tx["contractAddress"])
        sys.exit(0)
sys.exit(1)
' "$1" "$RUN"
}

TX_HASH=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["transactions"][0]["hash"])' "$RUN")
BLOCK=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(int(d["receipts"][0]["blockNumber"],16))' "$RUN")

ACCESS_MANAGER=$(addr_for AccessManager)
TOKEN_IMPL=$(addr_for Token)
IRS_IMPL=$(addr_for IdentityRegistryStorage)
MC_IMPL=$(addr_for ModularCompliance)
TREX_REGISTRY_IMPL=$(addr_for TREXRegistry)
AM_IMPL=$(addr_for TREXAccessManager)
IMPLEMENTATION_AUTHORITY=$(addr_for TREXImplementationAuthority)
TRUSTED_GATEWAY_REGISTRY=$(addr_for TrustedGatewayRegistry)
TREX_FACTORY=$(addr_for TREXFactory)

# Token is linked against TREXMessagingLib, TokenDelegationLib, TokenLedgerLib, TokenRecoveryLib and
# TokenGuardsLib; ModularCompliance against ModuleSetLib and TransferValidationLib (ComplianceLedgerLib is
# internal and never deployed). forge deploys each library ahead of the script's own transactions and records
# it under "libraries" as "<source>:<name>:<address>".
lib_addr() {
    python3 -c '
import json, sys
for entry in json.load(open(sys.argv[2])).get("libraries", []):
    source, name, address = entry.rsplit(":", 2)
    if name == sys.argv[1]:
        print(address)
        sys.exit(0)
sys.exit(1)
' "$1" "$RUN" || { echo "ERROR: $1 not found in $RUN libraries." >&2; exit 1; }
}
MESSAGING_LIB=$(lib_addr TREXMessagingLib)
DELEGATION_LIB=$(lib_addr TokenDelegationLib)
LEDGER_LIB=$(lib_addr TokenLedgerLib)
RECOVERY_LIB=$(lib_addr TokenRecoveryLib)
GUARDS_LIB=$(lib_addr TokenGuardsLib)
MODULE_SET_LIB=$(lib_addr ModuleSetLib)
TRANSFER_VALIDATION_LIB=$(lib_addr TransferValidationLib)

# beacons() returns a SuiteBeacons tuple (token, registry, irs, mc, accessManager) - fetch
# post-hoc, they're not top-level CREATEs.
BEACONS=$(cast call "$IMPLEMENTATION_AUTHORITY" "beacons()((address,address,address,address,address))" --rpc-url "$RPC_URL")

mkdir -p deployments
cat > "deployments/$NETWORK_NAME.json" <<JSON
{
  "chainId": $CHAIN_ID,
  "deployer": "$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")",
  "accessManager": "$ACCESS_MANAGER",
  "tokenImpl": "$TOKEN_IMPL",
  "messagingLib": "$MESSAGING_LIB",
  "delegationLib": "$DELEGATION_LIB",
  "ledgerLib": "$LEDGER_LIB",
  "recoveryLib": "$RECOVERY_LIB",
  "guardsLib": "$GUARDS_LIB",
  "moduleSetLib": "$MODULE_SET_LIB",
  "transferValidationLib": "$TRANSFER_VALIDATION_LIB",
  "identityRegistryStorageImpl": "$IRS_IMPL",
  "modularComplianceImpl": "$MC_IMPL",
  "trexRegistryImpl": "$TREX_REGISTRY_IMPL",
  "accessManagerImpl": "$AM_IMPL",
  "implementationAuthority": "$IMPLEMENTATION_AUTHORITY",
  "trustedGatewayRegistry": "$TRUSTED_GATEWAY_REGISTRY",
  "trexFactory": "$TREX_FACTORY",
  "beacons": "$BEACONS",
  "onchainidIdentityFactory": "$ONCHAINID_IDENTITY_FACTORY",
  "deployBlock": $BLOCK,
  "txHash": "$TX_HASH",
  "commit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
  "branch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
}
JSON

echo "Wrote deployments/$NETWORK_NAME.json"
echo "TREXFactory:   $TREX_FACTORY"
echo "AccessManager: $ACCESS_MANAGER"
