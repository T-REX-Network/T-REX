// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { DeployUtilityChecker } from "scripts/DeployUtilityChecker.s.sol";

import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

/// @notice Exercises `scripts/DeployUtilityChecker.s.sol` against a scratch manifest.
///
/// A fork simulation proves the script runs; only a test can assert that every pre-existing key
/// survived the manifest write, and that an upgrade keeps the proxy address while moving the
/// implementation. The scratch manifest lives under `cache/` (gitignored, and covered by
/// `fs_permissions`) and is addressed through `DEPLOYMENTS_FILE`, so `deployments/*.json` is never
/// touched.
///
/// This is deliberately one test function rather than six: the script is configured through
/// environment variables, `vm.setEnv` mutates the process environment, and test cases within a
/// suite may run concurrently — split across several tests they race on `UTILITY_CHECKER_*` and
/// fail nondeterministically. One function makes the ordering explicit.
contract DeployUtilityCheckerTest is Test {

    // EIP-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    /// @dev Mirrors the real `deployments/baseSepolia.json` shape: flat camelCase keys, two of
    ///      which are JSON numbers rather than strings.
    string internal constant SEED_MANIFEST = "{" '"chainId":84532,'
        '"deployer":"0x1B81EBEeec22281FF2fBCF990021B83b5204D4CE",'
        '"accessManager":"0x1f4F25fF509a1ed0e674d202927ac1F4a5866013",'
        '"tokenImpl":"0xfA846dfF30b2f8Ff2Bef3171094F39b420d949aa",'
        '"implementationAuthority":"0x4cD009f688a1cC6CEc9E3bDcF407919ffE1Ab4C2",'
        '"trexFactory":"0x003932f50f4bF38224cbd6405CE0dEe11c02941E",'
        '"beacons":"(0xeBE4f3ba3546f3F363BF6c69D5698D2173e4FD5F, 0x4eDDE67280BcE77F3eA74cECFAaf495999053DEE)",'
        '"deployBlock":46597470,' '"txHash":"0x7926a686ca149d767e050f522512765bb3f9b5d3d5ad77003da0a8db57316a4b"' "}";

    /// @dev Every key the seed manifest carries; none of them may disappear or change.
    string[9] internal SEED_KEYS = [
        "chainId",
        "deployer",
        "accessManager",
        "tokenImpl",
        "implementationAuthority",
        "trexFactory",
        "beacons",
        "deployBlock",
        "txHash"
    ];

    DeployUtilityChecker internal deployScript;
    string internal manifest;

    function setUp() public {
        deployScript = new DeployUtilityChecker();
        manifest = string.concat(vm.projectRoot(), "/cache/DeployUtilityChecker.t.json");
    }

    /// @notice Full script lifecycle: refusal with nothing recorded, first deployment, re-run
    ///         refusal, ownership-guarded upgrade, and the forced redeploy escape hatch — each
    ///         step re-checking that the manifest merge lost nothing.
    function test_ScriptLifecycle() public {
        vm.setEnv("DEPLOYMENTS_FILE", manifest);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("UTILITY_CHECKER_FORCE_REDEPLOY", "false");
        vm.setEnv("UTILITY_CHECKER_PROXY", vm.toString(address(0)));
        vm.writeFile(manifest, SEED_MANIFEST);

        // --- upgrade() with nothing recorded points at the first deployment ---
        vm.expectRevert(bytes("no utilityChecker recorded for this chain: run the first deployment instead"));
        deployScript.upgrade();

        // --- first deployment ---
        deployScript.run();

        string memory recorded = vm.readFile(manifest);
        address proxy = vm.parseJsonAddress(recorded, ".utilityChecker");
        address firstImpl = vm.parseJsonAddress(recorded, ".utilityCheckerImpl");

        assertTrue(proxy != address(0), "proxy not recorded");
        assertTrue(firstImpl != address(0), "implementation not recorded");
        assertTrue(proxy != firstImpl, "proxy and implementation must differ");
        assertEq(_implementationOf(proxy), firstImpl, "recorded impl is not the proxy's impl");
        assertEq(UtilityChecker(proxy).owner(), vm.addr(DEPLOYER_KEY), "deployer is not the owner");
        _assertSeedKeysIntact();

        // --- re-running the first deployment is refused ---
        vm.expectRevert(
            bytes(
                "UtilityChecker already recorded for this chain: use --sig \"upgrade()\", or set UTILITY_CHECKER_FORCE_REDEPLOY=true to replace the proxy"
            )
        );
        deployScript.run();

        // --- an upgrade cannot be pointed at a proxy the deployer does not own ---
        UtilityChecker foreignImpl = new UtilityChecker();
        vm.prank(address(0xBEEF));
        UtilityCheckerProxy foreign =
            new UtilityCheckerProxy(address(foreignImpl), abi.encodeCall(UtilityChecker.initialize, ()));
        assertEq(UtilityChecker(address(foreign)).owner(), address(0xBEEF), "foreign proxy owner mismatch");

        vm.setEnv("UTILITY_CHECKER_PROXY", vm.toString(address(foreign)));
        vm.expectRevert(bytes("deployer does not own the recorded UtilityChecker proxy"));
        deployScript.upgrade();
        vm.setEnv("UTILITY_CHECKER_PROXY", vm.toString(address(0)));

        // --- upgrade: implementation moves, proxy address does not ---
        deployScript.upgrade();

        string memory upgraded = vm.readFile(manifest);
        address secondImpl = vm.parseJsonAddress(upgraded, ".utilityCheckerImpl");
        assertEq(vm.parseJsonAddress(upgraded, ".utilityChecker"), proxy, "proxy address must not move on upgrade");
        assertTrue(secondImpl != firstImpl, "implementation should have changed");
        assertEq(_implementationOf(proxy), secondImpl, "proxy does not point at the recorded impl");
        _assertSeedKeysIntact();

        // --- the refusal is opt-out, not absolute ---
        vm.setEnv("UTILITY_CHECKER_FORCE_REDEPLOY", "true");
        deployScript.run();
        vm.setEnv("UTILITY_CHECKER_FORCE_REDEPLOY", "false");

        address replacement = vm.parseJsonAddress(vm.readFile(manifest), ".utilityChecker");
        assertTrue(replacement != proxy, "forced redeploy should record a new proxy");
        _assertSeedKeysIntact();
    }

    // ============ helpers ============

    /// @dev Re-reads the manifest and asserts every seed key is still present with its seed value.
    function _assertSeedKeysIntact() internal view {
        string memory current = vm.readFile(manifest);
        for (uint256 i = 0; i < SEED_KEYS.length; i++) {
            string memory key = string.concat(".", SEED_KEYS[i]);
            assertTrue(vm.keyExistsJson(current, key), string.concat("key lost from manifest: ", SEED_KEYS[i]));
            assertEq(
                keccak256(vm.parseJson(current, key)),
                keccak256(vm.parseJson(SEED_MANIFEST, key)),
                string.concat("key value changed: ", SEED_KEYS[i])
            );
        }
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

}
