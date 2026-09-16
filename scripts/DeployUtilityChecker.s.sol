// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

/// @title DeployUtilityChecker
/// @notice Deploys (or upgrades) the view-only `UtilityChecker` behind its UUPS proxy and
///         records the resulting addresses in the network's `deployments/*.json` manifest.
///
/// `UtilityChecker` is `UUPSUpgradeable` + `OwnableUpgradeable`, sitting behind a plain
/// `UtilityCheckerProxy` (an `ERC1967Proxy`). `initialize()` takes no arguments and makes
/// the caller — the broadcasting deployer — the owner, which is the account authorised to
/// run `upgradeToAndCall` later.
///
/// Two entry points, because the proxy address is the thing consumers pin:
///
///   `run()`      first deployment. Deploys implementation + proxy, records both. Refuses to
///                run if the manifest already records a checker (see `Re-runs` below).
///   `upgrade()`  implementation-only upgrade against the proxy already in the manifest. The
///                proxy address — and therefore the SDK manifest and every consumer config —
///                stays valid. Only `utilityCheckerImpl` changes.
///
/// Re-runs:
///   `run()` is deliberately refused when `utilityChecker` is already recorded for the chain.
///   A fresh proxy orphans the live one and silently invalidates every consumer pinned to the
///   old address, and with UUPS a new proxy is almost never what you want — `upgrade()` is.
///   To replace the proxy on purpose, set `UTILITY_CHECKER_FORCE_REDEPLOY=true`; the script
///   then proceeds and logs the superseded address loudly before overwriting it.
///
/// The manifest write is a merge, not a rewrite: the existing file is loaded with
/// `vm.serializeJson` and only `utilityChecker` / `utilityCheckerImpl` are added or replaced,
/// so every pre-existing key (factory, implementation authority, beacons, ...) survives.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY           private key that deploys, and that becomes the checker owner
///   UTILITY_CHECKER_FORCE_REDEPLOY optional, `run()` only. `true` allows overwriting an already
///                                  recorded proxy address. Default `false` (refuse).
///   UTILITY_CHECKER_PROXY          optional, `upgrade()` only. Overrides the proxy address read
///                                  from the manifest.
///   DEPLOYMENTS_FILE               optional. Manifest path for a chain this script has no name
///                                  mapping for. Default is derived from `block.chainid`.
///
/// Usage:
///   # first deployment
///   forge script scripts/DeployUtilityChecker.s.sol --rpc-url baseSepolia --broadcast
///
///   # implementation upgrade, same proxy address
///   forge script scripts/DeployUtilityChecker.s.sol --sig "upgrade()" --rpc-url baseSepolia --broadcast
///
/// Drop `--broadcast` to simulate. A simulation still writes the manifest (the JSON cheatcodes
/// are not transaction-gated), so check `git diff deployments/` after a dry run.
contract DeployUtilityChecker is Script {

    /// @dev Manifest key for the proxy — the address callers and the SDK use.
    string internal constant PROXY_KEY = "utilityChecker";

    /// @dev Manifest key for the implementation, kept so an upgrade is traceable.
    string internal constant IMPL_KEY = "utilityCheckerImpl";

    /// @dev Scratch object id for the JSON cheatcode serializer.
    string internal constant JSON_OBJECT = "trexDeployments";

    /// @notice First deployment: implementation + proxy, then record both.
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        string memory manifest = _manifestPath();
        string memory existing = vm.readFile(manifest);

        // Guard before broadcasting, so a refused re-run costs nothing.
        address recorded = _readRecorded(existing, PROXY_KEY);
        if (recorded != address(0)) {
            bool force = vm.envOr("UTILITY_CHECKER_FORCE_REDEPLOY", false);
            require(
                force,
                "UtilityChecker already recorded for this chain: use --sig \"upgrade()\", or set UTILITY_CHECKER_FORCE_REDEPLOY=true to replace the proxy"
            );
            console.log("!! FORCED REDEPLOY -- the recorded proxy below is about to be superseded");
            console.log("!! superseded utilityChecker:    ", recorded);
            console.log("!! superseded utilityCheckerImpl:", _readRecorded(existing, IMPL_KEY));
            console.log("!! consumers pinned to the old address will keep talking to the old contract");
        }

        vm.startBroadcast(deployerKey);

        UtilityChecker implementation = new UtilityChecker();
        UtilityCheckerProxy proxy =
            new UtilityCheckerProxy(address(implementation), abi.encodeCall(UtilityChecker.initialize, ()));

        vm.stopBroadcast();

        // `initialize()` runs in the proxy's constructor with the proxy as `msg.sender`'s callee,
        // so the owner is the broadcasting deployer. Assert it rather than assume it.
        address owner = UtilityChecker(address(proxy)).owner();
        require(owner == deployer, "UtilityChecker owner is not the deployer");

        _record(manifest, existing, address(proxy), address(implementation));

        console.log("chain id:                 ", block.chainid);
        console.log("UtilityChecker impl:      ", address(implementation));
        console.log("UtilityChecker proxy:     ", address(proxy));
        console.log("UtilityChecker owner:     ", owner);
        console.log("recorded in:              ", manifest);
    }

    /// @notice Implementation upgrade against the proxy already in the manifest.
    /// @dev The proxy address is unchanged, so no consumer config has to move.
    function upgrade() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        string memory manifest = _manifestPath();
        string memory existing = vm.readFile(manifest);

        // An unset — or explicitly zero — override falls back to the manifest.
        address proxy = vm.envOr("UTILITY_CHECKER_PROXY", address(0));
        if (proxy == address(0)) proxy = _readRecorded(existing, PROXY_KEY);
        require(proxy != address(0), "no utilityChecker recorded for this chain: run the first deployment instead");
        require(proxy.code.length > 0, "recorded utilityChecker has no code on this chain");

        // Guard: never point an upgrade at a proxy this deployer does not own. `_authorizeUpgrade`
        // is `onlyOwner`, so a foreign proxy would revert anyway — but only after we have paid to
        // deploy an implementation, and with a far less obvious message.
        address owner = UtilityChecker(proxy).owner();
        require(owner == deployer, "deployer does not own the recorded UtilityChecker proxy");

        address previousImpl = _readRecorded(existing, IMPL_KEY);

        vm.startBroadcast(deployerKey);

        UtilityChecker implementation = new UtilityChecker();
        UtilityChecker(proxy).upgradeToAndCall(address(implementation), "");

        vm.stopBroadcast();

        // The proxy key is re-written with the same value; only the impl key actually moves.
        _record(manifest, existing, proxy, address(implementation));

        console.log("chain id:                 ", block.chainid);
        console.log("UtilityChecker proxy:     ", proxy, "(unchanged)");
        console.log("UtilityChecker impl was:  ", previousImpl);
        console.log("UtilityChecker impl now:  ", address(implementation));
        console.log("recorded in:              ", manifest);
    }

    /// @dev Merges the two checker keys into the manifest, preserving every other key.
    ///      `vm.serializeJson` seeds the serializer with the file as it stands, so the write-back
    ///      is the original document plus/with the two keys updated — never a replacement.
    function _record(string memory path, string memory existing, address proxy, address implementation) internal {
        vm.serializeJson(JSON_OBJECT, existing);
        vm.serializeAddress(JSON_OBJECT, PROXY_KEY, proxy);
        string memory merged = vm.serializeAddress(JSON_OBJECT, IMPL_KEY, implementation);
        vm.writeJson(merged, path);
        // `writeJson` omits the trailing newline the manifests carry; put it back so the file
        // stays diff- and tooling-friendly.
        vm.writeFile(path, string.concat(vm.readFile(path), "\n"));
    }

    /// @dev Returns the address at `key`, or the zero address if the key is absent.
    function _readRecorded(string memory json, string memory key) internal view returns (address) {
        string memory path = string.concat(".", key);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return vm.parseJsonAddress(json, path);
    }

    /// @dev Picks the manifest from the chain id, so the same script serves other networks.
    ///      `DEPLOYMENTS_FILE` covers a chain with no name mapping yet.
    function _manifestPath() internal view returns (string memory) {
        string memory overridePath = vm.envOr("DEPLOYMENTS_FILE", string(""));
        if (bytes(overridePath).length > 0) return overridePath;

        string memory name;
        if (block.chainid == 84_532) {
            name = "baseSepolia";
        } else if (block.chainid == 936_485) {
            name = "zenith";
        } else {
            revert(
                string.concat(
                    "no deployments manifest mapped for chain id ",
                    vm.toString(block.chainid),
                    ": set DEPLOYMENTS_FILE, or add the chain to _manifestPath()"
                )
            );
        }
        return string.concat(vm.projectRoot(), "/deployments/", name, ".json");
    }

}
