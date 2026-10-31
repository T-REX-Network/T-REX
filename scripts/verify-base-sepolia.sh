#!/usr/bin/env bash
# Verifies the Base Sepolia T-REX deployment (deployments/baseSepolia.json) on Basescan.
# The original deploy ran with --verify but its broadcast record is gone, so each contract is
# verified on its own: constructor arguments are read back from the creation transaction and
# every external library is linked at its recorded address. Already-verified contracts are skipped.
#
# Usage: ./scripts/verify-base-sepolia.sh   (needs BASESCAN_API_KEY and ALCHEMY_KEY in .env)
set -uo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
[ -f .env ] && { set -a; source .env; set +a; }
: "${BASESCAN_API_KEY:?set in .env}"

D=deployments/baseSepolia.json
addr() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$D" "$1"; }

LIBS=(
  "contracts/token/TokenDelegationLib.sol:TokenDelegationLib:$(addr delegationLib)"
  "contracts/token/TokenGuardsLib.sol:TokenGuardsLib:$(addr guardsLib)"
  "contracts/token/TokenLedgerLib.sol:TokenLedgerLib:$(addr ledgerLib)"
  "contracts/interop/TREXMessagingLib.sol:TREXMessagingLib:$(addr messagingLib)"
  "contracts/compliance/modular/ModuleSetLib.sol:ModuleSetLib:$(addr moduleSetLib)"
  "contracts/token/TokenRecoveryLib.sol:TokenRecoveryLib:$(addr recoveryLib)"
  "contracts/compliance/modular/TransferValidationLib.sol:TransferValidationLib:$(addr transferValidationLib)"
)
LINK=()
for l in "${LIBS[@]}"; do LINK+=(--libraries "$l"); done

FAILED=()
verify() { # <address> <path:Contract> [extra forge flags]
  local address=$1 contract=$2; shift 2
  echo "== $contract at $address"
  forge verify-contract "$address" "$contract" --chain 84532 --etherscan-api-key "$BASESCAN_API_KEY" \
    --rpc-url baseSepolia --watch "${LINK[@]}" "$@" || FAILED+=("$contract $address")
}

# Libraries first: the contracts below link them.
for l in "${LIBS[@]}"; do verify "${l##*:}" "${l%:*}"; done

verify "$(addr accessManager)"               dependencies/@openzeppelin-contracts-5.7.0/access/manager/AccessManager.sol:AccessManager --guess-constructor-args
verify "$(addr tokenImpl)"                   contracts/token/Token.sol:Token
verify "$(addr identityRegistryStorageImpl)" contracts/registry/implementation/IdentityRegistryStorage.sol:IdentityRegistryStorage
verify "$(addr modularComplianceImpl)"       contracts/compliance/modular/ModularCompliance.sol:ModularCompliance
verify "$(addr accessManagerImpl)"           contracts/utils/TREXAccessManager.sol:TREXAccessManager
verify "$(addr trexRegistryImpl)"            contracts/registry/implementation/TREXRegistry.sol:TREXRegistry --guess-constructor-args
verify "$(addr implementationAuthority)"     contracts/proxy/beacon/TREXImplementationAuthority.sol:TREXImplementationAuthority --guess-constructor-args
verify "$(addr trustedGatewayRegistry)"      contracts/interop/TrustedGatewayRegistry.sol:TrustedGatewayRegistry --guess-constructor-args
verify "$(addr trexFactory)"                 contracts/factory/TREXFactory.sol:TREXFactory --guess-constructor-args
verify "$(addr utilityCheckerImpl)"          contracts/utils/UtilityChecker.sol:UtilityChecker
verify "$(addr utilityChecker)"              contracts/utils/UtilityCheckerProxy.sol:UtilityCheckerProxy --guess-constructor-args

if [ ${#FAILED[@]} -gt 0 ]; then
  printf 'Not verified:\n'; printf '  %s\n' "${FAILED[@]}"; exit 1
fi
echo "All contracts verified."
