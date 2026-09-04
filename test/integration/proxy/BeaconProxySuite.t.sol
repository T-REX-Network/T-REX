// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Version, VersionLib } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { MockTokenV2 } from "test/integration/mocks/MockTokenV2.sol";

contract BeaconProxySuiteTest is TREXSuiteTest {

    /// @dev ERC-1967 beacon slot (`bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`),
    ///      pre-computed once at the spec level. Used to read the beacon address straight out of
    ///      a `BeaconProxy`'s storage via `vm.load`, bypassing any selector-based lookup.
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @notice Behavior: a `BeaconProxy`-backed suite can run the full ERC-3643 happy path —
    ///         `mint`, `transfer`, `freezePartialTokens`. Confirms that swapping `*Proxy.sol`
    ///         wrappers for stock OZ `BeaconProxy` plus the `TREXImplementationAuthority` beacons
    ///         preserves end-to-end token semantics.
    function test_beaconProxySuite_happyPath_MintTransferFreeze() public {
        // mint
        vm.prank(agent);
        token.mint(alice, 1000);
        assertEq(token.balanceOf(alice), 1000, "Alice must hold the minted balance");

        // transfer
        vm.prank(agent);
        token.unpause();
        vm.prank(alice);
        token.transfer(bob, 300);
        assertEq(token.balanceOf(alice), 700, "Alice balance must drop by the transferred amount");
        assertEq(token.balanceOf(bob), 300, "Bob must receive the transferred amount");

        // freeze
        vm.prank(agent);
        token.freezePartialTokens(alice, 200);
        assertEq(token.getFrozenTokens(alice), 200, "Alice must have 200 tokens frozen");
    }

    /// @notice Behavior: `TREXImplementationAuthority.publishAndUpgrade` swaps the live `Token`
    ///         implementation under every shared-mode proxy. Before the upgrade,
    ///         `MockTokenV2(token).mockTokenV2Version()` reverts (selector not in v1). After the upgrade,
    ///         the same proxy returns `2`.
    function test_publishAndUpgrade_swapsLiveTokenImplementation() public {
        // pre-upgrade: v1 Token does not expose `version()`, so the call reverts
        vm.expectRevert();
        MockTokenV2(address(token)).mockTokenV2Version();

        // publish v5.0.1 with a MockTokenV2 implementation; every other impl stays put
        MockTokenV2 v2Implementation = new MockTokenV2();
        Version v1 = VersionLib.pack(5, 0, 1);
        ITREXImplementationAuthority.SuiteImplementations memory impls =
            ITREXImplementationAuthority.SuiteImplementations({
                tokenImplementation: address(v2Implementation),
                trexRegistryImplementation: address(trexRegistryImplementation),
                irsImplementation: address(identityRegistryStorageImplementation),
                mcImplementation: address(modularComplianceImplementation)
            });

        vm.prank(deployer);
        trexImplementationAuthority.publishAndUpgrade(v1, impls);

        // post-upgrade: the same proxy now resolves `version()` to v2's implementation
        assertEq(
            MockTokenV2(address(token)).mockTokenV2Version(), 2, "Token proxy must expose the v2 sentinel function"
        );
    }

    /// @notice Behavior: a `BeaconProxy`'s beacon slot is immutable for the lifetime of the proxy.
    ///         Even after `publishAndUpgrade` rotates the implementation behind the beacon, the
    ///         proxy's ERC-1967 beacon slot keeps pointing at the same beacon address. Reads the
    ///         slot directly via `vm.load` to bypass any selector-based getter.
    function test_publishAndUpgrade_doesNotChangeProxyBeaconSlot() public {
        bytes32 beaconBefore = vm.load(address(token), ERC1967_BEACON_SLOT);

        // publish a new version through the registry (same beacons, new impl)
        MockTokenV2 v2Implementation = new MockTokenV2();
        Version v1 = VersionLib.pack(5, 0, 1);
        ITREXImplementationAuthority.SuiteImplementations memory impls =
            ITREXImplementationAuthority.SuiteImplementations({
                tokenImplementation: address(v2Implementation),
                trexRegistryImplementation: address(trexRegistryImplementation),
                irsImplementation: address(identityRegistryStorageImplementation),
                mcImplementation: address(modularComplianceImplementation)
            });
        vm.prank(deployer);
        trexImplementationAuthority.publishAndUpgrade(v1, impls);

        bytes32 beaconAfter = vm.load(address(token), ERC1967_BEACON_SLOT);
        assertEq(beaconAfter, beaconBefore, "Token proxy beacon slot must be immutable across upgrades");
    }

}
